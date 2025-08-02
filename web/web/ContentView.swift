import SwiftUI
import AVKit

// ✅ 메인 브라우저 화면 View
struct ContentView: View {

    // 🔄 WebView 상태 모델 객체 생성
    @StateObject private var state = WebViewStateModel()

    // 🌐 입력창 URL 텍스트 바인딩 변수
    @State private var inputURL = "https://www.google.com"

    // 🔍 주소창 포커스 상태 관리
    @FocusState private var isTextFieldFocused: Bool

    // 🎬 AVPlayer 관련 상태
    @State private var playerURL: URL? = nil
    @State private var showAVPlayer: Bool = false

    // 🖼️ PIP 토글 상태 (UI는 숨기고 기능만 유지)
    @State private var enablePIP: Bool = true

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {

                // 🔗 상단 주소 입력창 및 이동 버튼
                HStack {
                    TextField("URL 또는 검색어 입력", text: $inputURL)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .focused($isTextFieldFocused)
                        .onTapGesture {
                            // 🟡 탭 시 전체 선택
                            isTextFieldFocused = true
                            DispatchQueue.main.async {
                                // UITextField 참조 후 전체 선택
                                UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                            }
                        }
                        .onSubmit {
                            // 엔터 입력 시 이동 처리
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

                    // ▶️ 이동 버튼
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

                // 🌐 WebView 표시
                CustomWebView(
                    stateModel: state,
                    playerURL: $playerURL,
                    showAVPlayer: $showAVPlayer
                )
                .edgesIgnoringSafeArea(.bottom)

                // ⬅️➡️🔄 하단 탐색 버튼 + 숨겨진 PIP 토글
                HStack {
                    // ⬅️ 뒤로가기 버튼
                    Button(action: { state.goBack() }) {
                        Image(systemName: "chevron.left").font(.title2)
                    }
                    .disabled(!state.canGoBack)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)

                    // ➡️ 앞으로가기 버튼
                    Button(action: { state.goForward() }) {
                        Image(systemName: "chevron.right").font(.title2)
                    }
                    .disabled(!state.canGoForward)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)

                    // 🔄 새로고침
                    Button(action: { state.reload() }) {
                        Image(systemName: "arrow.clockwise").font(.title2)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)

                    // 🕘 방문 기록 진입 버튼 (하단에 위치)
                    NavigationLink(destination: WebViewStateModel.HistoryPage(state: state)) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.title2)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)

                    Spacer()

                    // 🖼️ PIP 기능은 유지하되 UI 숨김
                    Toggle(isOn: $enablePIP) {
                        EmptyView()
                    }
                    .hidden()
                }
                .background(Color(UIColor.secondarySystemBackground))
            }

            // ✅ 상단 네비게이션바 제거 및 여백 제거
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
            .padding(.top, -8) // 상단 여백 제거
        }
        .ignoresSafeArea(.keyboard, edges: .top) // 키보드로 인한 여백 제거

        // ✅ 앱 실행 시 마지막 방문 페이지 로드
        .onAppear {
            if state.currentURL == nil {
                if let saved = UserDefaults.standard.string(forKey: "lastURL"),
                   let savedURL = URL(string: saved) {
                    state.currentURL = savedURL
                    inputURL = savedURL.absoluteString
                } else if let url = fixedURL(from: inputURL) {
                    state.currentURL = url
                }
            }
        }

        // ✅ WebView URL 변경 시 입력창 자동 반영
        .onReceive(state.$currentURL) { url in
            if let url = url {
                inputURL = url.absoluteString
            }
        }

        // ✅ AVPlayer 전체화면 전환
        .fullScreenCover(isPresented: $showAVPlayer) {
            if let url = playerURL {
                AVPlayerView(url: url)
            }
        }
    }

    // ✅ 문자열을 URL 또는 구글 검색으로 변환
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
}