import SwiftUI
import AVKit

// 🌐 브라우저 메인 UI를 구성하는 ContentView
struct ContentView: View {
    
    // 웹 상태 관리 모델 인스턴스 생성 (탐색/URL 등)
    @StateObject private var state = WebViewStateModel()
    
    // 사용자가 입력한 주소 또는 검색어 저장용
    @State private var inputURL = "https://www.google.com"
    
    // 텍스트 필드 포커스 상태 추적
    @FocusState private var isTextFieldFocused: Bool
    
    // AVPlayer 관련 상태값
    @State private var playerURL: URL? = nil
    @State private var showAVPlayer: Bool = false
    
    // PIP 모드 활성화 여부 (UI는 숨김)
    @State private var enablePIP: Bool = true

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                
                // 🔝 상단 주소 입력창과 이동 버튼
                HStack {
                    TextField("URL 또는 검색어", text: $inputURL)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .focused($isTextFieldFocused) // 포커스 상태 바인딩
                        .onTapGesture {
                            isTextFieldFocused = true // 탭 시 전체 포커스
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
                    
                    // ▶️ "이동" 버튼
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

                // 🌍 웹뷰 영역
                CustomWebView(
                    stateModel: state,
                    playerURL: $playerURL,
                    showAVPlayer: $showAVPlayer
                )
                .edgesIgnoringSafeArea(.bottom)

                // ⬇️ 하단 탐색 및 방문기록 버튼
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

                    // 🕘 방문기록 보기 버튼
                    NavigationLink(destination: WebViewStateModel.HistoryPage(state: state)) {
                        Image(systemName: "clock.arrow.circlepath").font(.title2)
                    }
                    .padding(.horizontal, 8)

                    Spacer()

                    // 🖼️ PIP 토글 (UI 숨김, 기능 유지)
                    Toggle(isOn: $enablePIP) {
                        Image(systemName: "pip.enter")
                    }
                    .labelsHidden()
                    .hidden()
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            .navigationBarHidden(true)
            .background(Color(UIColor.secondarySystemBackground))

            // 앱 시작 시 마지막 URL 불러오기
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

            // URL 변경 → 주소 입력창 업데이트
            .onReceive(state.$currentURL) { url in
                if let url = url {
                    inputURL = url.absoluteString
                }
            }

            // AVPlayer 전체화면 표시
            .fullScreenCover(isPresented: $showAVPlayer) {
                if let url = playerURL {
                    AVPlayerView(url: url)
                }
            }
        }
    }

    // 입력 텍스트 → URL 또는 구글 검색 URL로 변환
    private func fixedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. http/https로 시작 → 그대로 URL
        if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" {
            return url
        }

        // 2. 도메인 형식 → https:// 붙이기
        if trimmed.contains(".") && !trimmed.contains(" ") {
            return URL(string: "https://\(trimmed)")
        }

        // 3. 일반 검색어 → 구글 검색 URL
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }
}