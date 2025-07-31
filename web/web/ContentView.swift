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

                Button("이동") {
                    if let url = URL(string: inputURL), url.scheme != nil {
                        state.currentURL = url
                    }
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
            // 앱 시작 시 초기 URL 설정
            if state.currentURL == nil, let url = URL(string: inputURL) {
                state.currentURL = url
            }
        }
    }
}