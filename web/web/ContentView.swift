import SwiftUI

struct ContentView: View {
    @StateObject private var state = WebViewStateModel()
    @State private var inputURL = "https://www.apple.com"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("URL 입력", text: $inputURL)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    .onSubmit {
                        if let url = fixedURL(from: inputURL) {
                            state.currentURL = url
                        }
                    }

                Button("이동") {
                    if let url = fixedURL(from: inputURL) {
                        state.currentURL = url
                    }
                }
                .padding(.horizontal, 8)

                Button("새로고침") {
                    state.reload()
                }
                .padding(.horizontal, 8)
            }
            .padding(8)

            CustomWebView(stateModel: state)
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
            }
            .background(Color(UIColor.secondarySystemBackground))
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

        // 1. 정확한 URL (http/https)인 경우 바로 이동
        if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" {
            state.currentURL = url
            return
        }

        // 2. 스킴 없지만 도메인 형태 (예: apple.com)
        if trimmed.contains(".") && !trimmed.contains(" ") {
            if let url = URL(string: "https://\(trimmed)") {
                state.currentURL = url
                return
            }
        }

        // 3. 그 외는 무조건 구글 검색
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let searchURL = URL(string: "https://www.google.com/search?q=\(encoded)") {
            state.currentURL = searchURL
        }
    }

    private func fixedURL(from input: String) -> URL? {
        var input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !input.contains("://") {
            input = "https://" + input
        }
        return URL(string: input)
    }
}
