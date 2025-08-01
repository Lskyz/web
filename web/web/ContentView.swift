import SwiftUI

struct ContentView: View {
    @StateObject private var state = WebViewStateModel() // 웹 뷰 상태를 관리하는 모델
    @State private var inputURL = "https://www.apple.com" // 입력된 URL을 저장

    @State private var playerURL: URL? // 비디오 재생 URL
    @State private var showAVPlayer = false // AVPlayer의 표시 여부

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack {
                    // URL을 입력하는 텍스트 필드
                    TextField("URL 또는 검색어 입력", text: $inputURL, onCommit: {
                        loadInput() // 텍스트 필드에서 Enter를 눌렀을 때 호출되는 함수
                    })
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none) // 대문자 자동 변환 방지
                    .disableAutocorrection(true) // 자동 교정 방지
                    .keyboardType(.URL) // URL 타입 키보드 표시
                    .padding(.leading, 8)

                    // X 버튼: 주소 삭제 버튼 (URL 입력 필드 옆에 표시)
                    if !inputURL.isEmpty {
                        Button(action: {
                            inputURL = "" // X 버튼 클릭 시 입력 필드 내용 삭제
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary) // 버튼 색상
                        }
                        .buttonStyle(PlainButtonStyle()) // 기본 버튼 스타일 사용
                    }

                    // '이동' 버튼: URL을 입력하고 이동하는 버튼
                    Button("이동") {
                        loadInput() // 입력된 URL로 이동
                    }
                    .padding(.horizontal, 8)
                }
                .padding(8) // 상단에 패딩 추가

                // 웹뷰 감싸기, 끌어당기면 새로고침 기능 추가
                CustomWebView(stateModel: state, playerURL: $playerURL, showAVPlayer: $showAVPlayer)
                    .refreshable {
                        state.reload() // 상단을 끌어당기면 새로고침
                    }
                    .edgesIgnoringSafeArea(.bottom) // 화면 하단까지 확장

                // 하단 네비게이션 버튼들: 뒤로가기, 앞으로가기, 새로고침
                HStack {
                    // 뒤로가기 버튼
                    Button(action: { state.goBack() }) {
                        Image(systemName: "chevron.left") // 뒤로가기 아이콘
                    }
                    .disabled(!state.canGoBack) // 뒤로 갈 수 없으면 비활성화
                    .padding()

                    // 앞으로가기 버튼
                    Button(action: { state.goForward() }) {
                        Image(systemName: "chevron.right") // 앞으로가기 아이콘
                    }
                    .disabled(!state.canGoForward) // 앞으로 갈 수 없으면 비활성화
                    .padding()

                    // 새로고침 버튼
                    Button(action: {
                        state.reload() // 새로고침
                    }) {
                        Image(systemName: "arrow.clockwise") // 새로고침 아이콘
                    }
                    .padding()
                }
                .background(Color(UIColor.secondarySystemBackground)) // 배경색 설정
            }

            // AVPlayerOverlayView가 표시되는 영역
            if showAVPlayer, let url = playerURL {
                AVPlayerOverlayView(videoURL: url) {
                    showAVPlayer = false
                    playerURL = nil
                }
                .edgesIgnoringSafeArea(.all) // 화면 전체 영역으로 확장
                .background(Color.black.opacity(0.7)) // 배경을 어두운 색으로
                .transition(.opacity) // 전환 효과 (점점 사라지거나 나타남)
            }
        }
        .onAppear {
            // 화면이 나타날 때 처음 로드할 URL이 없으면 기본 URL로 로드
            if state.currentURL == nil {
                loadInput()
            }
        }
        .onReceive(state.$currentURL) { url in
            // 상태 모델에서 URL이 변경되면 입력 필드에 URL을 업데이트
            if let url = url {
                inputURL = url.absoluteString
            }
        }
    }

    private func loadInput() {
        // URL 입력 필드에서 앞뒤 공백을 제거
        let trimmed = inputURL.trimmingCharacters(in: .whitespacesAndNewlines)

        // http 또는 https로 시작하는 유효한 URL인 경우
        if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" {
            state.currentURL = url // URL 로딩
            return
        }

        // URL에 .이 포함되고 공백이 없으면 https:// 추가 후 로드
        if trimmed.contains(".") && !trimmed.contains(" ") {
            if let url = URL(string: "https://\(trimmed)") {
                state.currentURL = url
                return
            }
        }

        // URL이 아니면 구글 검색으로 처리
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let searchURL = URL(string: "https://www.google.com/search?q=\(encoded)") {
            state.currentURL = searchURL // 구글 검색 URL로 로드
        }
    }
}
