import SwiftUI

struct ContentView: View {
    @StateObject private var state = WebViewStateModel()
    @State private var inputURL = "https://www.google.com"
    @State private var visitHistory: [String] = []

    @FocusState private var isTextFieldFocused: Bool
    @State private var didSelectAll = false // ✅ 전체 선택 1회만 트리거

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                // ✅ 주소 입력창
                TextField("URL 입력", text: $inputURL)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    .focused($isTextFieldFocused)
                    .onChange(of: isTextFieldFocused) { focused in
                        // ✅ 처음 포커스 진입 시 전체 선택
                        if focused && !didSelectAll {
                            DispatchQueue.main.async {
                                // 커서 지연 후 전체 선택
                                UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                                didSelectAll = true
                            }
                        }
                    }
                    .onSubmit {
                        if let url = fixedURL(from: inputURL) {
                            state.currentURL = url
                            addToHistory(inputURL)
                        }
                        isTextFieldFocused = false
                        didSelectAll = false
                    }
                    .overlay(
                        HStack {
                            Spacer()
                            if !inputURL.isEmpty {
                                Button(action: {
                                    inputURL = ""
                                    didSelectAll = false
                                }) {
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
                    didSelectAll = false
                }
                .padding(.horizontal, 8)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            // ✅ 최근 방문 기록 표시
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
                                        didSelectAll = false
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
                .padding(.bottom, 0)
            }

            // ✅ 웹 뷰 본체
            CustomWebView(stateModel: state)
                .edgesIgnoringSafeArea(.bottom)

            // ✅ 하단 탐색 버튼
            HStack {
                Button(action: { state.goBack() }) {
                    Image(systemName: "chevron.left")
                        .font(.title2)
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
            // ✅ 앱 시작 시 기본 URL 설정
            if state.currentURL == nil {
                let initial = URL(string: "https://www.google.com")!
                state.currentURL = initial
                inputURL = initial.absoluteString
            }
        }
        .onReceive(state.$currentURL) { url in
            if let url = url {
                inputURL = url.absoluteString
            }
        }
    }

    // ✅ 입력을 URL 또는 검색어로 보정
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

    // ✅ 방문 기록 저장
    private func addToHistory(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && !visitHistory.contains(trimmed) {
            visitHistory.insert(trimmed, at: 0)
        }
    }

    // ✅ 방문 기록 삭제
    private func deleteHistory(at offsets: IndexSet) {
        let limited = Array(visitHistory.prefix(5))
        for index in offsets {
            if let originalIndex = visitHistory.firstIndex(of: limited[index]) {
                visitHistory.remove(at: originalIndex)
            }
        }
    }
}