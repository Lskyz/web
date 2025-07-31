import SwiftUI

struct ContentView: View {
    @StateObject private var state = WebViewStateModel()
    @State private var inputURL = "https://www.apple.com"

    @State private var playerURL: URL?
    @State private var showAVPlayer = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // URL 입력 및 이동 UI
                HStack {
                    TextField("URL 입력", text: $inputURL, onCommit: {
                        let fullURL = addSchemeIfNeeded(inputURL)
                        if let url = URL(string: fullURL) {
                            state.currentURL = url
                        }
                    })
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)

                    Button("이동") {
                        let fullURL = addSchemeIfNeeded(inputURL)
                        if let url = URL(string: fullURL) {
                            state.currentURL = url
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .padding(8)

                // CustomWebView에 AVPlayer 바인딩 전달 및 Pull to Refresh 구현
                CustomWebView(stateModel: state, playerURL: $playerURL, showAVPlayer: $showAVPlayer)
                    .edgesIgnoringSafeArea(.bottom)
                    .refreshable {
                        state.reload()
                    }

                // 네비게이션 버튼
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

            // AVPlayer 오버레이 뷰
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
            if state.currentURL == nil, let url = URL(string: addSchemeIfNeeded(inputURL)) {
                state.currentURL = url
            }
        }
    }

    // http/https 없으면 https:// 자동 추가
    private func addSchemeIfNeeded(_ urlString: String) -> String {
        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
            return urlString
        }
        return "https://" + urlString
    }
}