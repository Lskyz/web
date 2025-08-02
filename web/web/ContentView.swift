import SwiftUI
import AVKit

// 🌐 브라우저의 메인 화면 구성 View
struct ContentView: View {

    // WebView 상태 및 방문 기록 등을 관리하는 ViewModel
    @StateObject private var state = WebViewStateModel()

    // 사용자가 입력한 주소 또는 검색어 (텍스트 필드 바인딩)
    @State private var inputURL = "https://www.google.com"

    // 주소창 포커스 상태를 추적하기 위한 상태값
    @FocusState private var isTextFieldFocused: Bool

    // AVPlayer로 재생할 영상 URL 및 표시 여부 상태
    @State private var playerURL: URL? = nil
    @State private var showAVPlayer: Bool = false

    // PIP(Picture-in-Picture) 기능 활성화 여부 (UI는 숨기고 기능만 유지)
    @State private var enablePIP: Bool = true

    var body: some View {
        VStack(spacing: 0) {

            // 🔎 주소 입력창 + 이동 버튼 UI
            HStack {
                TextField("URL 또는 검색어", text: $inputURL)
                    .textFieldStyle(.roundedBorder) // 둥근 테두리 스타일
                    .autocapitalization(.none)      // 자동 대문자 끄기
                    .disableAutocorrection(true)     // 자동 수정 끄기
                    .keyboardType(.URL)              // URL용 키보드 제공
                    .focused($isTextFieldFocused)    // 포커스 상태 관리
                    .onTapGesture {
                        isTextFieldFocused = true   // 탭 시 전체 포커스
                    }
                    .onSubmit {
                        // 입력 후 return 키 누를 때: URL 혹은 검색어 처리
                        if let url = fixedURL(from: inputURL) {
                            state.currentURL = url
                        }
                        isTextFieldFocused = false
                    }
                    .overlay(
                        // ❌ 입력 지우기 버튼
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

                // ▶️ "이동" 버튼: 입력값 URL 로드 시도
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

            // 🌍 커스텀 WebView (WKWebView 래핑)
            CustomWebView(
                stateModel: state,
                playerURL: $playerURL,
                showAVPlayer: $showAVPlayer
            )
            .edgesIgnoringSafeArea(.bottom) // 하단 여백 없이 전체 표시

            // ⬅️➡️🔄 탐색 버튼 및 PIP UI
            HStack {
                // 뒤로가기
                Button(action: { state.goBack() }) {
                    Image(systemName: "chevron.left")
                        .font(.title2)
                }
                .disabled(!state.canGoBack) // 뒤로가기 불가능할 땐 비활성화
                .padding(.vertical, 6)
                .padding(.horizontal, 8)

                // 앞으로가기
                Button(action: { state.goForward() }) {
                    Image(systemName: "chevron.right")
                        .font(.title2)
                }
                .disabled(!state.canGoForward)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)

                // 새로고침
                Button(action: { state.reload() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.title2)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)

                Spacer()

                // 🖼️ PIP (Picture-in-Picture) 토글 - UI는 숨김
                Toggle(isOn: $enablePIP) {
                    Image(systemName: "pip.enter")
                        .font(.title3)
                }
                .labelsHidden()
                .hidden() // 👈 UI는 보이지 않지만 기능은 작동함
            }
            .background(Color(UIColor.secondarySystemBackground))
        }

        // 🟡 앱 실행 시 마지막 URL 또는 기본 URL 로드
        .onAppear {
            if state.currentURL == nil {
                if let saved = UserDefaults.standard.string(forKey: "lastURL"),
                   let savedURL = URL(string: saved) {
                    state.currentURL = savedURL
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

        // 🎥 AVPlayer 표시 (전체화면 모달)
        .fullScreenCover(isPresented: $showAVPlayer) {
            if let url = playerURL {
                AVPlayerView(url: url) // 사용자 정의 VideoPlayerView
            }
        }

        // 🕘 방문기록 보기 버튼
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                NavigationLink(destination: WebViewStateModel.HistoryPage(state: state)) {
                    Image(systemName: "clock.arrow.circlepath")
                }
            }
        }
    }

    // 📌 입력값을 URL 또는 구글 검색 URL로 보정하는 함수
    private func fixedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. http/https로 시작하는 경우는 그대로 사용
        if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" {
            return url
        }

        // 2. 도메인처럼 보이면 https 붙여서 사용
        if trimmed.contains(".") && !trimmed.contains(" ") {
            return URL(string: "https://\(trimmed)")
        }

        // 3. 공백 포함된 검색어인 경우 → 구글 검색 URL로 변환
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }
}