import Foundation
import Combine
import SwiftUI  // 뷰를 위한 import 추가

class WebViewStateModel: ObservableObject {
    @Published private(set) var currentURL: URL? = nil {
        didSet {
            if let url = currentURL {
                UserDefaults.standard.set(url.absoluteString, forKey: "lastURL")
                addToHistory(url)
            }
        }
    }

    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var playerURL: URL? = nil
    @Published var showAVPlayer = false

    // ✅ 방문기록 관련
    @Published var history: [URL] = [] {
        didSet { saveHistory() }
    }

    private let maxHistoryCount = 100

    init() {
        loadHistory()
        if let lastURLString = UserDefaults.standard.string(forKey: "lastURL"),
           let url = URL(string: lastURLString) {
            self.currentURL = url
        }
    }

    func setCurrentURL(_ url: URL) {
        self.currentURL = url
    }

    private func addToHistory(_ url: URL) {
        guard !history.contains(url) else { return }
        history.append(url)
        if history.count > maxHistoryCount {
            history.removeFirst(history.count - maxHistoryCount)
        }
    }

    private func saveHistory() {
        let strings = history.map { $0.absoluteString }
        UserDefaults.standard.set(strings, forKey: "history")
    }

    private func loadHistory() {
        if let stored = UserDefaults.standard.array(forKey: "history") as? [String] {
            self.history = stored.compactMap { URL(string: $0) }
        }
    }

    func clearHistory() {
        history.removeAll()
        UserDefaults.standard.removeObject(forKey: "history")
    }

    func removeHistoryItem(_ url: URL) {
        history.removeAll { $0 == url }
    }

    func goBack() {
        NotificationCenter.default.post(name: Notification.Name("WebViewGoBack"), object: nil)
    }

    func goForward() {
        NotificationCenter.default.post(name: Notification.Name("WebViewGoForward"), object: nil)
    }

    func reload() {
        NotificationCenter.default.post(name: Notification.Name("WebViewReload"), object: nil)
    }

    // ✅ 내부에 방문기록 뷰 정의
    struct HistoryPage: View {
        @ObservedObject var state: WebViewStateModel

        var body: some View {
            List {
                if !state.history.isEmpty {
                    Section {
                        Button(role: .destructive) {
                            state.clearHistory()
                        } label: {
                            HStack {
                                Spacer()
                                Text("전체 삭제")
                                Spacer()
                            }
                        }
                    }
                }

                Section(header: Text("방문 기록")) {
                    ForEach(state.history.reversed(), id: \.self) { url in
                        HStack {
                            Button(action: {
                                state.setCurrentURL(url)
                            }) {
                                Text(url.absoluteString)
                                    .lineLimit(1)
                                    .foregroundColor(.primary)
                            }

                            Spacer()

                            Button(action: {
                                state.removeHistoryItem(url)
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("방문기록")
        }
    }
}