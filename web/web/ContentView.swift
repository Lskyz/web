import SwiftUI

struct ContentView: View {
    @StateObject private var state = WebViewStateModel()
    @State private var inputURL = "https://www.google.com" // ✅ 첫 로딩 구글
    @State private var visitHistory: [String] = []

    // ✅ 포커스 상태: 주소창에 커서가 있는지 여부
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                // ✅ 주소 입력 필드 + X버튼 + 포커스 추적
                TextField("URL 입력", text: $inputURL)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    .focused($isTextFieldFocused) // 포커스 바인딩
                    .onSubmit {
                        if let url = fixedURL(from: inputURL) {
                            state.currentURL = url
                            addToHistory(inputURL)
                        }
                        isTextFieldFocused = false // 제출 후 포커스 해제
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
                        addToHistory(inputURL)
                    }
                    isTextFieldFocused = false
                }
                .padding(.horizontal, 8)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            // ✅ 주소창에 포커스가 있을 때만 최근 방문 표시
            if isTextFieldFocused && !visitHistory.isEmpty {
                List {
                    Section {
                        ForEach(visitHistory.prefix(5), id: \.self) { item in
                            Text(item)
                                .font(.caption2)
                                .foregroundColor(.gray)
                                .onTapGesture {
                                    inputURL = item
                                    if let url = fixedURL(from: item) {
                                        state.currentURL = url
                                        isTextFieldFocused = false
                                    }
                                }
                        }
                        .onDelete(perform: deleteHistory)
                    } header: {
                        Text("최근 방문")
                            .font(.caption)
                            .padding(.bottom, 0)
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: 140)
                .padding(.horizontal, 8)
                .padding(.bottom, 0) // ✅ 주소창과 간격 최소화
            }

            // ✅ 웹 콘텐츠
            CustomWebView(stateModel: state)
                .edgesIgnoringSafeArea(.bottom)

            // ✅ 하단 탐색 버튼 (아이콘 크기 ↑, 여백 ↓)
            HStack {
                Button(action: { state.goBack() }) {
                    Image(systemName: "chevron.left")
                        .font(.title2) // 아이콘 크기 키움
                }
                .disabled(!state.canGoBack)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)

                Button(action: { state.goForward() }) {
                    Image(systemName: "chevron.right")
                        .font(.title2)
                }
                .disabled(!state.canGoForward)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)

                Button(action: { state.reload() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.title2)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
            }
            .background(Color(UIColor.secondarySystemBackground))
        }
        .onAppear {
            // ✅ 앱 첫 실행 시 구글 홈페이지 로드
            if state.currentURL == nil {
                state.currentURL = URL(string: "https://www.google.com")
                inputURL = "https://www.google.com"
            }
        }
        .onReceive(state.$currentURL) { url in
            if let url = url {
                inputURL = url.absoluteString
            }
        }
    }

    // ✅ 입력 텍스트를 URL 또는 검색어로 변환
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

    // ✅ 방문 기록에 추가 (중복 방지)
    private func addToHistory(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && !visitHistory.contains(trimmed) {
            visitHistory.insert(trimmed, at: 0)
        }
    }

    // ✅ 방문 기록 삭제 (스와이프)
    private func deleteHistory(at offsets: IndexSet) {
        let limited = Array(visitHistory.prefix(5))
        for index in offsets {
            if let originalIndex = visitHistory.firstIndex(of: limited[index]) {
                visitHistory.remove(at: originalIndex)
            }
        }
    }
}
