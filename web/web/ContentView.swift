import SwiftUI
import AVKit

// ✅ 메인 브라우저 화면
struct ContentView: View {
    @StateObject private var state = WebViewStateModel()     // 🔄 상태 모델 (WebView 및 기록 관리)
    @State private var inputURL = "https://www.google.com"   // 🌐 초기 입력 URL
    @FocusState private var isTextFieldFocused: Bool         // 🔍 주소창 포커스 상태 관리

    // 🎥 AVPlayer 재생 제어용
    @State private var playerURL: URL? = nil
    @State private var showAVPlayer: Bool = false

    // 📺 PIP (Picture-in-Picture) 활성화 여부 (UI는 숨김)
    @State private var enablePIP: Bool = true

    var body: some View {
        VStack(spacing: 0) {

            // 🔗 주소창 + 이동 버튼
            HStack {
                TextField("URL 입력", text: $inputURL)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    .focused($isTextFieldFocused) // ✅ 포커스 적용
                    .onTapGesture { isTextFieldFocused = true } // ✅ 탭 시 전체 선택
                    .onSubmit {
                        if let url = fixedURL(from: inputURL) {
                            state.currentURL = url // 🔧 수정됨: setCurrentURL(url) → currentURL 직접 할당
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

                // "이동" 버튼
                Button("이동") {
                    if let url = fixedURL(from: inputURL) {
                        state.currentURL = url // 🔧 수정됨
                    }
                    isTextFieldFocused = false
                }
                .padding(.horizontal, 8)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            // 🌐 커스텀 WebView
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

                // 📺 PIP 토글 (기능 유지하되 UI는 숨김)
                Toggle(isOn: $enablePIP) {
                    Image(systemName: "pip.enter").font(.title3)
                }
                .labelsHidden()
                .hidden() // 👻 UI는 숨김
            }
            .background(Color(UIColor.secondarySystemBackground))
        }

        // 🟢 앱 실행 시 초기 로딩 주소 설정
        .onAppear {
            if state.currentURL == nil {
                if let saved = UserDefaults.standard.string(forKey: "lastURL"),
                   let savedURL = URL(string: saved) {
                    state.currentURL = savedURL // 🔧 수정됨
                } else if let url = fixedURL(from: inputURL) {
                    state.currentURL = url // 🔧 수정됨
                }
            }
        }

        // 🎬 외부에서 AVPlayer 표시 여부 감지
        .sheet(isPresented: $showAVPlayer) {
            if let playerURL = playerURL {
                VideoPlayer(player: AVPlayer(url: playerURL))
            }
        }

        // 📌 네비게이션으로 방문기록 보기 버튼
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                NavigationLink(destination: WebViewStateModel.HistoryPage(state: state)) {
                    Image(systemName: "clock.arrow.circlepath") // 시계 + 기록 아이콘
                }
            }
        }
    }

    // 🔧 입력 문자열을 유효한 URL로 보정
    func fixedURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        } else {
            return URL(string: "https://" + trimmed)
        }
    }
}