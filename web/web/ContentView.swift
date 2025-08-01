import SwiftUI

struct ContentView: View {
    @StateObject private var state = WebViewStateModel()
    @State private var inputURL = "https://www.apple.com"

    @State private var playerURL: URL?
    @State private var showAVPlayer = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack {
                    TextField("URL 또는 검색어 입력", text: $inputURL, onCommit: {
                        loadInput()
                    })
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)

                    if !inputURL.isEmpty {
                        Button(action: {
                            inputURL = ""
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }

                    Button("이동") {
                        loadInput()
                    }
                    .padding(.horizontal, 8)
                }
                .padding(8)

                // 웹뷰 바로 감싸서 끌어당겨 새로고침 추가
                CustomWebView(stateModel: state, playerURL: $playerURL, showAVPlayer: $showAVPlayer)
                    .refreshable {
                        state.reload()
                    }
                    .edgesIgnoringSafeArea(.bottom)

                HStack {
                    Button(action: { state.goBack() }) {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!state.canGoBack)
                    .padding()

                    Button(action: { state.goForward() }) {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!state.canGoForward)
                    .padding()

                    Button(action: {
                        state.reload()
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .padding()
                }
                .background(Color(UIColor.secondarySystemBackground))
            }

            if showAVPlayer, let url = playerURL {
                AVPlayerOverlayView(videoURL: url) {
                    showAVPlayer = false
                    playerURL = nil
                }
                .edgesIgnoringSafeArea(.all)
                .background(Color.black.opacity(0.7))
                .transition(.opacity)
            }
        }
        .onAppear {
            if state.currentURL == nil {
                loadInput()
            }
        }
        .onReceive(state.$currentURL) { url in
            if let url = url {
                inputURL = url.absoluteString
            }
        }
    }

    private func loadInput() {
        let trimmed = inputURL.trimmingCharacters(in: .whitespacesAndNewlines)

        if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" {
            state.currentURL = url
            return
        }

        if trimmed.contains(".") && !trimmed.contains(" ") {
            if let url = URL(string: "https://\(trimmed)") {
                state.currentURL = url
                return
            }
        }

        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let searchURL = URL(string: "https://www.google.com/search?q=\(encoded)") {
            state.currentURL = searchURL
        }
    }
}
