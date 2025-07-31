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

                Button("즐겨찾기") {
                    if let url = state.currentURL, !state.bookmarks.contains(url) {
                        state.bookmarks.append(url)
                    }
                }
                .padding(.horizontal, 8)
            }
            .padding(8)

            CustomWebView(stateModel: state)
                .edgesIgnoringSafeArea(.bottom)

            HStack {
                Button(action: { if state.canGoBack { state.currentURL = nil; state.currentURL = state.currentURL } }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!state.canGoBack)
                .padding()

                Button(action: { if state.canGoForward { state.currentURL = nil; state.currentURL = state.currentURL } }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!state.canGoForward)
                .padding()
            }
            .background(Color(UIColor.secondarySystemBackground))

            List {
                Section(header: Text("즐겨찾기")) {
                    ForEach(state.bookmarks, id: \.self) { url in
                        Button(action: {
                            state.currentURL = url
                            inputURL = url.absoluteString
                        }) {
                            Text(url.absoluteString)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .onDelete { state.bookmarks.remove(atOffsets: $0) }
                }
            }
            .listStyle(.plain)
        }
    }
}
