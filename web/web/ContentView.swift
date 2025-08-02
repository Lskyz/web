import SwiftUI
import AVKit

// ✅ 메인 브라우저 화면
struct ContentView: View {
    @StateObject private var state = WebViewStateModel()     // 🔄 상태 객체
    @State private var inputURL = "https://www.google.com"   // 🌐 입력 주소 초기값
    @FocusState private var isTextFieldFocused: Bool         // 🔍 포커스 상태
    @State private var textFieldSelectedAll = false          // 📌 전체 선택 제어용

    // 🎬 AVPlayer 재생용
    @State private var playerURL: URL? = nil
    @State private var showAVPlayer: Bool = false

    // 🔄 PIP 사용 여부 (UI는 숨기되 기능은 유지 가능)
    @State private var enablePIP: Bool = true

    var body: some View {
        // ✅ NavigationView로 감싸서 NavigationLink 작동하게 함
        NavigationView {
            VStack(spacing: 0) {
                // 🔗 상단 주소창 + 이동 버튼
                HStack {
                    TextField("URL 입력", text: $inputURL)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .focused($isTextFieldFocused)
                        .onTapGesture {
                            // 👉 커서 클릭 시 전체 선택
                            if !textFieldSelectedAll {
                                DispatchQueue.main.async {
                                    self.inputURL = self.inputURL
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

                    Button("이동") {
                        if let url = fixedURL(from: inputURL) {
                            state.currentURL = url
                        }
                        isTextFieldFocused = false
                    }
                    .padding(.horizontal, 8)
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)

                // 🌐 웹 페이지 표시 영역
                CustomWebView(
                    stateModel: state,
                    playerURL: $playerURL,
                    showAVPlayer: $showAVPlayer
                )
                .edgesIgnoringSafeArea(.bottom)

                // ⬅️➡️🔄 하단 내비게이션 버튼들
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

                    // 🔄 새로고침 버튼
                    Button(action: { state.reload() }) {
                        Image(systemName: "arrow.clockwise").font(.title2)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)

                    // 🕘 방문 기록 보기 버튼 (새 페이지 이동)
                    NavigationLink(destination: WebViewStateModel.HistoryPage(state: state)) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.title2)
                            .padding(.horizontal, 8)
                    }

                    Spacer()

                    // 🖼 PIP 기능 토글 (UI 숨김 가능)
                    Toggle(isOn: $enablePIP) {
                        Image(systemName: "pip.enter").font(.title3)
                    }
                    .labelsHidden()
                    .padding(.horizontal, 10)
                }
                .background(Color(UIColor.secondarySystemBackground))
            }
            // 네비게이션바 숨김 (상단 제목 줄 제거)
            .navigationBarHidden(true)
        }
        // 🌐 앱 실행 시 마지막 URL 불러오기
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

        // 🔁 주소 입력창 자동 업데이트
        .onReceive(state.$currentURL) { url in
            if let url = url {
                inputURL = url.absoluteString
            }
        }

        // 🎬 영상 전체 화면 전환
        .fullScreenCover(isPresented: $showAVPlayer) {
            if let url = playerURL {
                AVPlayerView(url: url)
            }
        }
    }

    // ✅ 입력 텍스트를 URL로 변환하거나 구글 검색으로 처리
    private func fixedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // http 또는 https로 시작하면 그대로 사용
        if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" {
            return url
        }

        // 도메인 형태면 https:// 붙이기
        if trimmed.contains(".") && !trimmed.contains(" ") {
            return URL(string: "https://\(trimmed)")
        }

        // 그 외는 구글 검색으로 처리
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }
}