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

    // ☑️ 전체 선택 중복 방지용 상태값
    @State private var textFieldSelectedAll = false

    // 🎬 AVPlayer 관련 상태
    @State private var playerURL: URL? = nil
    @State private var showAVPlayer: Bool = false

    // 🖼️ PIP 토글 상태 (UI는 숨기고 기능만 유지)
    @State private var enablePIP: Bool = true

    // 📜 방문기록 sheet 열기 여부
    @State private var showHistorySheet = false

    // 🧭 [추가] 탭 매니저 진입용
    @State private var showTabs = false

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
                        if !textFieldSelectedAll {
                            DispatchQueue.main.async {
                                self.inputURL = self.inputURL // 값 변경 트리거
                                UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                                textFieldSelectedAll = true
                            }
                        }
                    }
                    .onChange(of: isTextFieldFocused) { focused in
                        if !focused {
                            textFieldSelectedAll = false
                        }
                    }
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
            .padding(.top, 4) // 꼭대기 여백 최소화

            // 🌐 WebView 표시
            CustomWebView(
                stateModel: state,
                playerURL: $playerURL,
                showAVPlayer: $showAVPlayer
            )

            // ⬅️➡️🔄 하단 탐색 버튼 + 방문기록 + 탭 진입 버튼
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

                // 🧭 [추가] 탭 매니저 진입 버튼
                Button(action: {
                    showTabs = true
                }) {
                    Image(systemName: "square.on.square")
                        .font(.title2)
                }
                .padding(.horizontal, 8)

                Spacer()

                // 🖼️ PIP 토글 (UI 숨김)
                Toggle(isOn: $enablePIP) {
                    Image(systemName: "pip.enter")
                }
                .labelsHidden()
                .hidden()
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 6)
            .background(Color(UIColor.secondarySystemBackground))
        }
        .ignoresSafeArea(.keyboard)

        // 앱 시작 시 마지막 URL 로드
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

        // 주소창 동기화
        .onReceive(state.$currentURL) { url in
            if let url = url {
                inputURL = url.absoluteString
            }
        }

        // AVPlayer 전체화면
        .fullScreenCover(isPresented: $showAVPlayer) {
            if let url = playerURL {
                AVPlayerView(url: url)
            }
        }

        // 방문기록 시트
        .sheet(isPresented: $showHistorySheet) {
            NavigationView {
                WebViewStateModel.HistoryPage(state: state)
            }
        }

        // 탭 매니저로 진입
        .fullScreenCover(isPresented: $showTabs) {
            NavigationView {
                TabManager()
            }
        }
    }

    // ✅ 문자열 → URL 또는 검색 URL로 변환
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