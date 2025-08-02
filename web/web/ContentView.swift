import SwiftUI
import AVKit

struct ContentView: View {
    @StateObject private var state = WebViewStateModel()
    @State private var inputURL = "https://www.google.com" // ✅ 초기 주소
    @State private var visitHistory: [String] = []

    @FocusState private var isTextFieldFocused: Bool

    // ✅ AVPlayer 전환용 상태
    @State private var playerURL: URL? = nil
    @State private var showAVPlayer: Bool = false

    // ✅ PIP 사용 여부 (토글용)
    @State private var enablePIP: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                // ✅ 주소창 + X버튼 + 포커스 추적
                TextField("URL 입력", text: $inputURL)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    .focused($isTextFieldFocused)
                    .onTapGesture {
                        // ✅ 포커스되면 전체 선택
                        DispatchQueue.main.async {
                            UITextField.appearance().selectAll(nil)
                        }
                    }
                    .onSubmit {
                        if let url = fixedURL(from: inputURL) {
                            state.currentURL = url
                            addToHistory(inputURL)
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
                        addToHistory(inputURL)
                    }
                    isTextFieldFocused = false
                }
                .padding(.horizontal, 8)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            // ✅ 최근 방문 리스트 (포커스 상태일 때만)
            if isTextFieldFocused && !visitHistory.isEmpty {
                List {
                    Section {
                        ForEach(visitHistory.prefix(5), id: \.self) { item in
                            Text(item)
                                .font(.caption2)
                                .foregroundColor(.gray)
                                .onTapGesture {
                                    inputURL = item
                                    if let url = fixedURL(from: item) {
                                        state.currentURL = url
                                        isTextFieldFocused = false
                                    }
                                }
                        }
                        .onDelete(perform: deleteHistory)
                    } header: {
                        Text("최근 방문")
                            .font(.caption)
                            .padding(.bottom, 0)
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: 140)
                .padding(.horizontal, 8)
                .padding(.bottom, 0)
            }

            // ✅ WebView
            CustomWebView(stateModel: state,
                          playerURL: $playerURL,
                          showAVPlayer: $showAVPlayer)
                .edgesIgnoringSafeArea(.bottom)

            // ✅ 하단 탐색 + PIP 토글
            HStack {
                Button(action: { state.goBack() }) {
                    Image(systemName: "chevron.left")
                        .font(.title2)
                }
                .disabled(!state.canGoBack)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)

                Button(action: { state.goForward() }) {
                    Image(systemName: "chevron.right")
                        .font(.title2)
                }
                .disabled(!state.canGoForward)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)

                Button(action: { state.reload() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.title2)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)

                Spacer()

                Toggle(isOn: $enablePIP) {
                    Image(systemName: "pip.enter")
                        .font(.title3)
                }
                .labelsHidden()
                .padding(.horizontal, 10)
                .onChange(of: enablePIP) { value in
                    // 필요 시 PIP 사용 여부를 webview에 반영 가능
                }
            }
            .background(Color(UIColor.secondarySystemBackground))
        }
        .onAppear {
            if state.currentURL == nil {
                state.currentURL = URL(string: "https://www.google.com")
                inputURL = "https://www.google.com"
            }
        }
        .onReceive(state.$currentURL) { url in
            if let url = url {
                inputURL = url.absoluteString
            }
        }
        .fullScreenCover(isPresented: $showAVPlayer) {
            // ✅ AVPlayerViewController를 통한 비디오 재생
            if let url = playerURL {
                AVPlayerView(url: url)
                    .edgesIgnoringSafeArea(.all)
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

    private func addToHistory(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && !visitHistory.contains(trimmed) {
            visitHistory.insert(trimmed, at: 0)
        }
    }

    private func deleteHistory(at offsets: IndexSet) {
        let limited = Array(visitHistory.prefix(5))
        for index in offsets {
            if let originalIndex = visitHistory.firstIndex(of: limited[index]) {
                visitHistory.remove(at: originalIndex)
            }
        }
    }
}