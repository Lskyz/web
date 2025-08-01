import SwiftUI
import WebKit

struct CustomWebView: UIViewRepresentable {
    @ObservedObject var stateModel: WebViewStateModel
    @Binding var playerURL: URL?
    @Binding var showAVPlayer: Bool

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator

        if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard let targetURL = stateModel.currentURL else { return }
        if uiView.url != targetURL {
            uiView.load(URLRequest(url: targetURL))
        }
    }

    func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: CustomWebView

        init(_ parent: CustomWebView) {
            self.parent = parent
            super.init()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.parent.stateModel.currentURL = webView.url
        }
    }
}

struct ContentView: View {
    @StateObject private var state = WebViewStateModel() // 웹 뷰 상태를 관리하는 모델
    @State private var inputURL = "https://www.apple.com" // 입력된 URL을 저장

    @State private var playerURL: URL? // 비디오 재생 URL
    @State private var showAVPlayer = false // AVPlayer의 표시 여부

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack {
                    ZStack {
                        // URL을 입력하는 텍스트 필드
                        TextField("URL 또는 검색어 입력", text: $inputURL, onCommit: {
                            loadInput() // 텍스트 필드에서 Enter를 눌렀을 때 호출되는 함수
                        })
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none) // 대문자 자동 변환 방지
                        .disableAutocorrection(true) // 자동 교정 방지
                        .keyboardType(.URL) // URL 타입 키보드 표시
                        .padding(.leading, 8)

                        // X 버튼: 주소 삭제 버튼 (URL 입력 필드 안쪽에 표시)
                        if !inputURL.isEmpty {
                            Button(action: {
                                inputURL = "" // X 버튼 클릭 시 입력 필드 내용 삭제
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary) // 버튼 색상
                                    .padding(.trailing, 8)
                            }
                            .buttonStyle(PlainButtonStyle()) // 기본 버튼 스타일 사용
                            .offset(x: 130) // X 버튼 위치 조정
                        }
                    }

                    // '이동' 버튼: URL을 입력하고 이동하는 버튼
                    Button("이동") {
                        loadInput() // 입력된 URL로 이동
                    }
                    .padding(.horizontal, 8)
                }
                .padding(8) // 상단에 패딩 추가

                // ScrollView로 감싸서 `refreshable` 사용 가능하게 함
                ScrollView {
                    CustomWebView(stateModel: state, playerURL: $playerURL, showAVPlayer: $showAVPlayer)
                        .refreshable {
                            state.reload() // 상단을 끌어당기면 새로고침
                        }
                        .edgesIgnoringSafeArea(.bottom) // 화면 하단까지 확장
                }

                // 하단 네비게이션 버튼들: 뒤로가기, 앞으로가기, 새로고침
                HStack {
                    // 뒤로가기 버튼
                    Button(action: { state.goBack() }) {
                        Image(systemName: "chevron.left") // 뒤로가기 아이콘
                    }
                    .disabled(!state.canGoBack) // 뒤로 갈 수 없으면 비활성화
                    .padding()

                    // 앞으로가기 버튼
                    Button(action: { state.goForward() }) {
                        Image(systemName: "chevron.right") // 앞으로가기 아이콘
                    }
                    .disabled(!state.canGoForward) // 앞으로 갈 수 없으면 비활성화
                    .padding()

                    // 새로고침 버튼 (하단)
                    Button(action: {
                        state.reload() // 하단 새로고침
                    }) {
                        Image(systemName: "arrow.clockwise") // 새로고침 아이콘
                    }
                    .padding()
                }
                .background(Color(UIColor.secondarySystemBackground))
            }

            // AVPlayerOverlayView가 표시되는 영역
            if showAVPlayer, let url = playerURL {
                AVPlayerOverlayView(videoURL: url) {
                    showAVPlayer = false
                    playerURL = nil
                }
                .edgesIgnoringSafeArea(.all) // 화면 전체 영역으로 확장
                .background(Color.black.opacity(0.7)) // 배경을 어두운 색으로
                .transition(.opacity) // 전환 효과 (점점 사라지거나 나타남)
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
