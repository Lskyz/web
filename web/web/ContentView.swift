import SwiftUI
import AVKit

// ✅ 메인 브라우저 화면
struct ContentView: View {
    @StateObject private var state = WebViewStateModel()       // 🔄 WebView 상태 객체
    @State private var inputURL = "https://www.google.com"     // 🌐 주소 입력창 초기값
    @FocusState private var isTextFieldFocused: Bool           // 🔍 텍스트 필드 포커스 상태

    // 🎬 AVPlayer 관련 상태값
    @State private var playerURL: URL? = nil
    @State private var showAVPlayer: Bool = false

    // 🖼️ PIP 기능 토글 상태값 (UI는 숨겨져 있음)
    @State private var enablePIP: Bool = true

    var body: some View {
        NavigationView { // 방문 기록 진입 위해 NavigationView는 필요
            VStack(spacing: 0) {
                
                // 🔗 상단 주소창 + 이동 버튼 UI
                HStack {
                    TextField("URL 또는 검색어 입력", text: $inputURL)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .focused($isTextFieldFocused)
                        .onTapGesture {
                            // 👉 커서 위치 시 전체 선택
                            DispatchQueue.main.async {
                                isTextFieldFocused = true
                            }
                        }
                        .onSubmit {
                            // 리턴 키 입력 시 이동
                            if let url = fixedURL(from: inputURL) {
                                state.currentURL = url
                            }
                            isTextFieldFocused = false
                        }
                        .overlay(
                            // ❌ 텍스트 클리어 버튼
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
                .padding(.bottom, 6) // 상단 여백 제거 후 하단 여백만

                // 🌐 WebView 본체 표시
                CustomWebView(
                    stateModel: state,
                    playerURL: $playerURL,
                    showAVPlayer: $showAVPlayer
                )
                .edgesIgnoringSafeArea(.bottom)

                // ⬅️➡️🔄 하단 탐색 + 방문 기록
                HStack {
                    // ◀️ 뒤로 가기
                    Button(action: { state.goBack() }) {
                        Image(systemName: "chevron.left").font(.title2)
                    }
                    .disabled(!state.canGoBack)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)

                    // ▶️ 앞으로 가기
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

                    // 🕘 방문 기록 보기 (NavigationLink)
                    NavigationLink(destination: WebViewStateModel.HistoryPage(state: state)) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.title2)
                            .padding(.horizontal, 8)
                    }

                    Spacer()

                    // 👻 PIP 기능 (숨김)
                    Toggle(isOn: $enablePIP) {
                        Image(systemName: "pip.enter").font(.title3)
                    }
                    .labelsHidden()
                    .hidden()
                }
                .background(Color(UIColor.secondarySystemBackground))
            }
            .ignoresSafeArea(.container, edges: .top) // ✅ 상단 safe area 무시
        }

        // 🌐 앱 시작 시 마지막 URL 불러오기 또는 기본 URL
        .onAppear {
            if state.currentURL == nil {
                if let saved = UserDefaults.standard.string(forKey: "lastURL"),
                   let savedURL = URL(string: saved) {
                    state.currentURL = savedURL
                    inputURL = savedURL.absoluteString
                } else {
                    let url = URL(string: "https://www.google.com")!
                    state.currentURL = url
                    inputURL = url.absoluteString
                }
            }
        }

        // 🔁 URL 변경 시 TextField 자동 반영
        .onReceive(state.$currentURL) { url in
            if let url = url {
                inputURL = url.absoluteString
            }
        }

        // 🎬 AVPlayer 전환
        .fullScreenCover(isPresented: $showAVPlayer) {
            if let url = playerURL {
                AVPlayerView(url: url)
            }
        }
    }

    // ✅ 입력 텍스트 → URL 또는 구글 검색 URL로 변환
    private func fixedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // http/https URL
        if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" {
            return url
        }

        // 도메인으로 보이면 https 붙이기
        if trimmed.contains(".") && !trimmed.contains(" ") {
            return URL(string: "https://\(trimmed)")
        }

        // 검색어 처리
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }
}