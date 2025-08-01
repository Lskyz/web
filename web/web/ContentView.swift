import SwiftUI

struct ContentView: View {
    // 웹뷰 상태를 관리하는 모델 (뒤로가기/앞으로가기 가능 여부 등)
    @StateObject private var state = WebViewStateModel()
    
    // 주소 입력 필드 값
    @State private var inputURL = "https://www.apple.com"

    var body: some View {
        VStack(spacing: 0) {
            // 상단 주소 입력 영역
            HStack {
                // URL 입력 필드 + X버튼 (오른쪽에 오버레이로)
                TextField("URL 입력", text: $inputURL)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    .onSubmit {
                        if let url = fixedURL(from: inputURL) {
                            state.currentURL = url
                        }
                    }
                    .overlay(
                        HStack {
                            Spacer()
                            if !inputURL.isEmpty {
                                // X 버튼: 입력값 초기화
                                Button(action: { inputURL = "" }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.gray)
                                }
                                .padding(.trailing, 8)
                            }
                        }
                    )

                // 이동 버튼: 입력된 주소로 이동
                Button("이동") {
                    if let url = fixedURL(from: inputURL) {
                        state.currentURL = url
                    }
                }
                .padding(.horizontal, 8)
            }
            .padding(8)

            // 웹 콘텐츠 표시 영역
            CustomWebView(stateModel: state)
                .edgesIgnoringSafeArea(.bottom)

            // 하단 뒤로/앞으로/새로고침 버튼
            HStack {
                // 뒤로가기 버튼
                Button(action: { state.goBack() }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!state.canGoBack)
                .padding()

                // 앞으로가기 버튼
                Button(action: { state.goForward() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!state.canGoForward)
                .padding()

                // 새로고침 버튼
                Button(action: { state.reload() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .padding()
            }
            .background(Color(UIColor.secondarySystemBackground))
        }
        .onAppear {
            // 앱이 처음 나타날 때 초기 URL 설정
            if state.currentURL == nil {
                loadInput()
            }
        }
        .onReceive(state.$currentURL) { url in
            // 웹뷰가 이동한 URL을 주소 입력창에 반영
            if let url = url {
                inputURL = url.absoluteString
            }
        }
    }

    // 입력된 텍스트를 기반으로 URL 판단 → 웹뷰로 전달
    private func loadInput() {
        let trimmed = inputURL.trimmingCharacters(in: .whitespacesAndNewlines)

        // 정확한 URL (http:// 또는 https://)인 경우
        if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" {
            state.currentURL = url
            return
        }

        // 도메인 형태 (예: apple.com)인 경우 https:// 붙이기
        if trimmed.contains(".") && !trimmed.contains(" ") {
            if let url = URL(string: "https://\(trimmed)") {
                state.currentURL = url
                return
            }
        }

        // 그 외는 구글 검색으로 처리
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let searchURL = URL(string: "https://www.google.com/search?q=\(encoded)") {
            state.currentURL = searchURL
        }
    }

    // 입력값을 URL로 해석하거나 구글 검색 URL로 fallback
    private func fixedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // http:// 또는 https:// 있는 경우 그대로 사용
        if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" {
            return url
        }

        // 도메인으로 판단되면 https:// 추가
        if trimmed.contains(".") && !trimmed.contains(" ") {
            return URL(string: "https://\(trimmed)")
        }

        // 검색어는 구글 검색 URL로 변환
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }
}
