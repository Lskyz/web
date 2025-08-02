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

    // 🔄 PIP 사용 여부 (UI는 숨김)
    @State private var enablePIP: Bool = true

    // 📜 방문기록 sheet 열기 여부
    @State private var showHistorySheet = false

    var body: some View {
        VStack(spacing: 0) {

            // 🔗 주소창 + 이동 버튼
            HStack {
                TextField("URL 또는 검색어", text: $inputURL)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    .focused($isTextFieldFocused)
                    .onTapGesture {
                        // 전체 선택 자동
                        DispatchQueue.main.async {
                            self.isTextFieldFocused = true
                            UITextField.appearance().selectAll(nil)
                        }
                    }
                    .onSubmit {
                        // 입력값 처리
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
            .padding(.top, 4) // 꼭대기 여백 최소화

            // 🌐 WebView 삽입
            CustomWebView(
                stateModel: state,
                playerURL: $playerURL,
                showAVPlayer: $showAVPlayer
            )

            // ⬅️➡️🔄 하단 탐색 버튼 + 방문기록
            HStack {
                // ◀️ 뒤로가기
                Button(action: { state.goBack() }) {
                    Image(systemName: "chevron.left").font(.title2)
                }
                .disabled(!state.canGoBack)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)

                // ▶️ 앞으로가기
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

                // 🕘 방문기록 보기
                Button(action: {
                    showHistorySheet = true
                }) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title2)
                }
                .padding(.horizontal, 8)

                Spacer()

                // 🖼 PIP (UI는 숨김)
                Toggle(isOn: $enablePIP) {
                    Image(systemName: "pip.enter").font(.title3)
                }
                .labelsHidden()
                .hidden() // UI 숨기기
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 6)
            .background(Color(UIColor.secondarySystemBackground))
        }
        .ignoresSafeArea(.keyboard) // 키보드 시 뷰 밀림 방지

        // 🟡 앱 실행 시 마지막 URL 또는 기본 URL 로드
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

        // 🔁 WebView URL 변경 → 주소 입력창 자동 업데이트
        .onReceive(state.$currentURL) { url in
            if let url = url {
                inputURL = url.absoluteString
            }
        }

        // 🎥 AVPlayer 전체화면 표시
        .fullScreenCover(isPresented: $showAVPlayer) {
            if let url = playerURL {
                AVPlayerView(url: url)
            }
        }

        // 📜 방문기록 페이지를 sheet로 표시
        .sheet(isPresented: $showHistorySheet) {
            NavigationView {
                WebViewStateModel.HistoryPage(state: state)
            }
        }
    }

    // ✅ 입력된 문자열 → URL 객체로 변환
    private func fixedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. http/https 스킴 포함
        if let url = URL(string: trimmed),
           url.scheme == "http" || url.scheme == "https" {
            return url
        }

        // 2. 도메인 형식
        if trimmed.contains(".") && !trimmed.contains(" ") {
            return URL(string: "https://\(trimmed)")
        }

        // 3. 검색어 → 구글 검색 URL
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }
}