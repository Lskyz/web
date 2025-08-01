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
            if state.currentURL == nil, let url = fixedURL(from: inputURL) {
                state.currentURL = url
            }
        }
    }
    
    func f
