import SwiftUI
import AVKit

// ✅ 메인 브라우저 화면
struct ContentView: View {
    @StateObject private var state = WebViewStateModel()     // 🔄 상태 객체
    @State private var inputURL = "https://www.google.com"   // 🌐 입력 주소 초기값
    @FocusState private var isTextFieldFocused: Bool         // 🔍 포커스 상태
    @State private var showHistoryPage = false               // 📘 방문기록 보기 상태

    // 🎬 AVPlayer 재생용
    @State private var playerURL: URL? = nil
    @State private var showAVPlayer: Bool = false

    // 🔄 PIP 사용 여부 (향후 연동 가능)
    @State private var enablePIP: Bool = true

    var body: some View {
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
                        .onTapGesture { isTextFieldFocused = true }     // ✅ 탭 시 전체 선택 포커스
                        .onSubmit {
                            if let url = fixedURL(from: inputURL) {
                                state.setCurrentURL(url)
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
                            state.setCurrentURL(url)
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

                // ⬅️➡️🔄 하단 탐색 버튼 + 기록 버튼 + PIP
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

                    // 📘 방문기록 보기 버튼
                    NavigationLink(
                        destination: WebViewStateModel.HistoryPage(state: state),
                        isActive: $showHistoryPage
                    ) {
                        Button(action: {
                            showHistoryPage = true
                        }) {
                            Image(systemName: "book")
                                .font(.title3)
                        }
                    }
                    .padding(.horizontal, 8)

                    // 👻 PIP 토글 UI 숨김 (기능은 유지)
                    Toggle(isOn: $enablePIP) {
                        Image(systemName: "pip.enter").font(.title3)
                    }
                    .labelsHidden()
                    .hidden()     // 👻 PIP 토글 UI 숨김
                }
                .background(Color(UIColor.secondarySystemBackground))
            }
            .onAppear {
                if state.currentURL == nil {
                    if let lastURLString = UserDefaults.standard.string(forKey: "lastURL"),
                       let url = URL(string: lastURLString) {
                        state.setCurrentURL(url)
                        inputURL = url.absoluteString
                    }
                }
            }
        }
    }

    // 🔧 URL 문자열을 http/https 기반으로 고정
    func fixedURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        } else {
            return URL(string: "https://" + trimmed)
        }
    }
}