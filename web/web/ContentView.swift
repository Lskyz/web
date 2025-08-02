import SwiftUI
import AVKit

// ✅ 메인 브라우저 화면
struct ContentView: View {
    @StateObject private var state = WebViewStateModel()     // 🔄 상태 객체
    @State private var inputURL = "https://www.google.com"   // 🌐 입력 주소 초기값
    @FocusState private var isTextFieldFocused: Bool         // 🔍 포커스 상태

    // 🎬 AVPlayer 재생용
    @State private var playerURL: URL? = nil
    @State private var showAVPlayer: Bool = false

    // 🔄 PIP 사용 여부 (향후 연동 가능)
    @State private var enablePIP: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            // 🔗 상단 주소창 + 이동 버튼
            HStack {
                TextField("URL 입력", text: $inputURL)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        if let url = fixedURL(from: inputURL) {
                            state.currentURL = url
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
                    }
                    isTextFieldFocused = false
                }
                .padding(.horizontal, 8)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            // 🌐 WebView 삽입
            CustomWebView(
                stateModel: state,
                playerURL: $playerURL,
                showAVPlayer: $showAVPlayer
            )
            .edgesIgnoringSafeArea(.bottom)

            // ⬅️➡️🔄 하단 탐색 버튼 + PIP 토글
            HStack {
                Button(action: { state.goBack() }) {
                    Image(systemName: "chevron.left").font(.title2)
                }
                .disabled(!state.canGoBack)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)

                Button(action: { state.goForward() }) {
                    Image(systemName: "chevron.right").font(.title2)
                }
                .disabled(!state.canGoForward)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)

                Button(action: { state.reload() }) {
                    Image(systemName: "arrow.clockwise").font(.title2)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)

                Spacer()

                Toggle(isOn: $enablePIP) {
                    Image(systemName: "pip.enter").font(.title3)
                }
                .labelsHidden()
                .padding(.horizontal, 10)
            }
            .background(Color(UIColor.secondarySystemBackground))
        }

        // 🌐 앱 실행 시 초기 로딩
        .onAppear {
            if state.currentURL == nil {
                let url = URL(string: "https://www.google.com")!
                state.currentURL = url
                inputURL = url.absoluteString
            }
        }

        // 🔁 WebView URL 바뀌면 입력창도 업데이트
        .onReceive(state.$currentURL) { url in
            if let url = url {
                inputURL = url.absoluteString
            }
        }

        // 🎬 AVPlayer 전체화면 전환
        .fullScreenCover(isPresented: $showAVPlayer) {
            if let url = playerURL {
                AVPlayerView(url: url)
            }
        }
    }

    // ✅ 입력된 문자열 → URL 객체로 변환
    private func fixedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. 스킴 있는 정식 주소
        if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" {
            return url
        }

        // 2. 도메인 형식
        if trimmed.contains(".") && !trimmed.contains(" ") {
            return URL(string: "https://\(trimmed)")
        }

        // 3. 검색어 처리 (Google)
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }
}