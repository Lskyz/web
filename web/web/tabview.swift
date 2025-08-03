import SwiftUI

// MARK: - 탭 하나를 구성하는 데이터 구조
struct WebTab: Identifiable, Equatable {
    let id: UUID
    let stateModel: WebViewStateModel            // ✅ 네가 만든 상태 모델
    var playerURL: URL?                          // ✅ AVPlayer용 URL
    var showAVPlayer: Bool                       // ✅ AVPlayer 표시 여부

    var currentURL: URL? {
        stateModel.currentURL
    }

    init(url: URL) {
        self.id = UUID()
        self.stateModel = WebViewStateModel()
        self.stateModel.currentURL = url
        self.playerURL = nil
        self.showAVPlayer = false
    }

    static func == (lhs: WebTab, rhs: WebTab) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 실제 탭 UI를 제어하는 뷰
struct TabManager: View {
    @Environment(\.dismiss) private var dismiss     // ✅ 복귀용

    @State private var tabs: [WebTab]
    @State private var selectedTabID: UUID

    // ✅ CustomWebView에서 연동될 바인딩용 상태
    @State private var inputURL: String = ""
    @State private var isTextFieldFocused: Bool = false
    @State private var textFieldSelectedAll: Bool = false

    init() {
        let firstTab = WebTab(url: URL(string: "https://www.google.com")!)
        _tabs = State(initialValue: [firstTab])
        _selectedTabID = State(initialValue: firstTab.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 🔗 주소창 + 이동 버튼
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
                                self.inputURL = self.inputURL
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
                        if let url = fixedURL(from: inputURL),
                           let index = tabs.firstIndex(where: { $0.id == selectedTabID }) {
                            tabs[index].stateModel.currentURL = url
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
                    if let url = fixedURL(from: inputURL),
                       let index = tabs.firstIndex(where: { $0.id == selectedTabID }) {
                        tabs[index].stateModel.currentURL = url
                    }
                    isTextFieldFocused = false
                }
                .padding(.horizontal, 8)
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            // 상단 탭 목록
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(tabs) { tab in
                        Button(action: {
                            selectedTabID = tab.id
                            inputURL = tab.currentURL?.absoluteString ?? ""
                        }) {
                            Text(tab.currentURL?.host ?? "탭")
                                .padding(8)
                                .background(tab.id == selectedTabID ? Color.blue : Color.gray)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        .contextMenu {
                            Button("탭 닫기") {
                                closeTab(tab)
                            }
                        }
                    }

                    Button(action: {
                        addNewTab()
                    }) {
                        Image(systemName: "plus")
                            .padding(8)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                }
                .padding(.horizontal)
            }

            Divider()

            // 실제 웹뷰 표시
            if let index = tabs.firstIndex(where: { $0.id == selectedTabID }) {
                let tab = tabs[index]

                CustomWebView(
                    stateModel: tab.stateModel,
                    playerURL: Binding(
                        get: { tabs[index].playerURL },
                        set: { tabs[index].playerURL = $0 }
                    ),
                    showAVPlayer: Binding(
                        get: { tabs[index].showAVPlayer },
                        set: { tabs[index].showAVPlayer = $0 }
                    )
                )
                .onReceive(tab.stateModel.$currentURL) { newURL in
                    if tab.id == selectedTabID, let url = newURL {
                        inputURL = url.absoluteString
                    }
                }
                .background(
                    NavigationLink(
                        destination: AVPlayerView(url: tab.playerURL ?? URL(string: "about:blank")!),
                        isActive: Binding(
                            get: { tabs[index].showAVPlayer },
                            set: { tabs[index].showAVPlayer = $0 }
                        )
                    ) {
                        EmptyView()
                    }
                    .hidden()
                )
            } else {
                Text("탭 없음")
            }

            Divider()

            // ✅ 하단 제어 + 닫기 버튼 추가
            HStack {
                Button(action: {
                    dismiss()
                }) {
                    Label("닫기", systemImage: "chevron.down")
                        .padding(8)
                }

                Spacer()

                Button(action: {
                    if let tab = tabs.first(where: { $0.id == selectedTabID }) {
                        closeTab(tab)
                    }
                }) {
                    Text("현재 탭 닫기")
                        .padding(8)
                }
            }
            .background(Color(UIColor.secondarySystemBackground))
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

    private func addNewTab() {
        let newTab = WebTab(url: URL(string: "https://www.apple.com")!)
        tabs.append(newTab)
        selectedTabID = newTab.id
        inputURL = newTab.currentURL?.absoluteString ?? ""
    }

    private func closeTab(_ tab: WebTab) {
        if let index = tabs.firstIndex(of: tab) {
            tabs.remove(at: index)

            if tabs.isEmpty {
                addNewTab()
            } else if selectedTabID == tab.id {
                selectedTabID = tabs.first!.id
                inputURL = tabs.first!.currentURL?.absoluteString ?? ""
            }
        }
    }
}