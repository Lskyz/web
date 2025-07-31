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

                    Button("이동") {
                        loadInput()
                    }
                    .padding(.horizontal, 8)
                }
                .padding(8)

                CustomWebView(stateModel: state, playerURL: $playerURL, showAVPlayer: $showAVPlayer)
                    .edgesIgnoringSafeArea(.bottom)
                    .refreshable {
                        state.reload()
                    }

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
        if let url = urlFrom(input: trimmed) {
            state.currentURL = url
        } else if let googleSearchURL = googleSearchURL(query: trimmed) {
            state.currentURL = googleSearchURL
        }
    }

    private func urlFrom(input: String) -> URL? {
        if let url = URL(string: input), url.scheme == "http" || url.scheme == "https" {
            return url
        } else if let url = URL(string: "https://\(input)"), UIApplication.shared.canOpenURL(url) {
            return url
        }
        return nil
    }

    private func googleSearchURL(query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }
}