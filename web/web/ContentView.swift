import SwiftUI

struct ContentView: View {
    @StateObject private var state = WebViewStateModel()
    @State private var inputURL = "https://www.apple.com"
    
    // ✅ 방문 기록 배열
    @State private var visitHistory: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                // ✅ 주소 입력 필드 + X 버튼
                TextField("URL 입력", text: $inputURL)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    .onSubmit {
                        if let url = fixedURL(from: inputURL) {
                            state.currentURL = url
                            addToHistory(inputURL)
                        }
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

                // ✅ 이동 버튼
                Button("이동") {
                    if let url = fixedURL(from: inputURL) {
                        state.currentURL = url
                        addToHistory(inputURL)
                    }
                }
                .padding(.horizontal, 8)
            }
            .padding(8)

            // ✅ 방문 기록 목록 (최대 5개) + 스와이프 삭제 기능
            if !visitHistory.isEmpty {
                List {
                    Section(header: Text("최근 방문").font(.caption)) {
                        ForEach(visitHistory.prefix(5), id: \.self) { item in
                            Text(item)
                                .font(.caption2)
                                .foregroundColor(.gray)
                                .onTapGesture {
                                    inputURL = item
                                    if let url = fixedURL(from: item) {
                                        state.currentURL = url
                                    }
                                }
                        }
                        .onDelete(perform: deleteHistory)
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: 160) // 방문기록 리스트 높이 제한
            }

            // ✅ 웹 콘텐츠 영역
            CustomWebView(stateModel: state)
                .edgesIgnoringSafeArea(.bottom)

            // ✅ 하단 탐색 버튼들 (여백 축소)
            HStack {
                Button(action: { state.goBack() }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!state.canGoBack)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)

                Button(action: { state.goForward() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!state.canGoForward)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)

                Button(action: { state.reload() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
            }
            .background(Color(UIColor.secondarySystemBackground))
        }
        .onAppear {
            if state.currentURL == nil {
                loadInput()
            }
        }
        .onReceive(state.$currentURL) { url in
            if let url = url {
                inputURL = url.absoluteString
            }
        }
    }

    // ✅ 주소 입력값을 URL 또는 검색어로 처리
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

    // ✅ 앱 시작 시 주소 자동 로드
    private func loadInput() {
        let trimmed = inputURL.trimmingCharacters(in: .whitespacesAndNewlines)

        if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" {
            state.currentURL = url
            return
        }

        if trimmed.contains(".") && !trimmed.contains(" ") {
            if let url = URL(string: "https://\(trimmed)") {
                state.currentURL = url
                return
            }
        }

        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let searchURL = URL(string: "https://www.google.com/search?q=\(encoded)") {
            state.currentURL = searchURL
        }
    }

    // ✅ 중복 없이 방문 기록 추가
    private func addToHistory(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && !visitHistory.contains(trimmed) {
            visitHistory.insert(trimmed, at: 0)
        }
    }

    // ✅ 방문 기록에서 항목 삭제 (스와이프 삭제 동작)
    private func deleteHistory(at offsets: IndexSet) {
        // prefix로 잘라진 리스트 기준이므로 원본 인덱스로 변환
        let limited = Array(visitHistory.prefix(5))
        for index in offsets {
            if let originalIndex = visitHistory.firstIndex(of: limited[index]) {
                visitHistory.remove(at: originalIndex)
            }
        }
    }
}
