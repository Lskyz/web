import SwiftUI
import WebKit

// MARK: - 히스토리 페이지 UI
extension WebViewDataModel {

    // navigateToIndex: UI에서 특정 히스토리 항목으로 이동할 때 사용 (메타데이터 반환 전용)
    // 실제 네비게이션은 호출자가 webView.load() 로 처리
    func navigateToIndex(_ index: Int) -> PageRecord? {
        guard index >= 0, index < pageHistory.count else { return nil }
        return pageHistory[index]
    }

    public struct HistoryPage: View {
        @ObservedObject var dataModel: WebViewDataModel
        let onNavigateToPage: (PageRecord) -> Void
        let onNavigateToURL: (URL) -> Void

        @State private var searchQuery: String = ""
        @Environment(\.dismiss) private var dismiss

        private let dateFormatter: DateFormatter = {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            return df
        }()

        public init(dataModel: WebViewDataModel,
                    onNavigateToPage: @escaping (PageRecord) -> Void,
                    onNavigateToURL: @escaping (URL) -> Void) {
            self.dataModel = dataModel
            self.onNavigateToPage = onNavigateToPage
            self.onNavigateToURL = onNavigateToURL
        }

        private var sessionHistory: [PageRecord] { dataModel.pageHistory.reversed() }

        private var filteredGlobalHistory: [HistoryEntry] {
            let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if q.isEmpty { return WebViewDataModel.globalHistory.sorted { $0.date > $1.date } }
            return WebViewDataModel.globalHistory
                .filter { $0.url.absoluteString.lowercased().contains(q) || $0.title.lowercased().contains(q) }
                .sorted { $0.date > $1.date }
        }

        public var body: some View {
            List {
                if !sessionHistory.isEmpty {
                    Section("현재 세션 (\(sessionHistory.count)개)") {
                        ForEach(sessionHistory) { record in
                            SessionHistoryRowView(
                                record: record,
                                isCurrent: record.id == dataModel.currentPageRecord?.id
                            )
                            .onTapGesture { onNavigateToPage(record); dismiss() }
                        }
                    }
                }

                Section("전체 기록 (\(filteredGlobalHistory.count)개)") {
                    ForEach(filteredGlobalHistory) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "globe").frame(width: 16, height: 16).foregroundColor(.blue)
                                Text(item.title).font(.headline).lineLimit(1)
                                Spacer()
                                Text(dateFormatter.string(from: item.date)).font(.caption2).foregroundColor(.secondary)
                            }
                            Text(item.url.absoluteString).font(.caption).foregroundColor(.gray).lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .onTapGesture { onNavigateToURL(item.url); dismiss() }
                    }
                    .onDelete(perform: deleteGlobalHistory)
                }
            }
            .navigationTitle("방문 기록")
            .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .always))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("모두 지우기") { dataModel.clearHistory() }
                }
            }
        }

        func deleteGlobalHistory(at offsets: IndexSet) {
            let items = filteredGlobalHistory
            let targets = offsets.map { items[$0] }
            WebViewDataModel.globalHistory.removeAll { targets.contains($0) }
            WebViewDataModel.saveGlobalHistory()
        }
    }
}

// MARK: - 세션 히스토리 행 뷰
struct SessionHistoryRowView: View {
    let record: PageRecord
    let isCurrent: Bool

    private var icon: String {
        switch record.navigationType {
        case .home: return "house.fill"
        case .reload: return "arrow.clockwise"
        case .spaNavigation: return "sparkles"
        case .userClick: return "hand.tap.fill"
        default: return "circle"
        }
    }

    private var iconColor: Color {
        switch record.navigationType {
        case .home: return .green
        case .reload: return .orange
        case .spaNavigation: return .blue
        case .userClick: return .red
        default: return .gray
        }
    }

    var body: some View {
        HStack {
            Image(systemName: isCurrent ? "arrow.right.circle.fill" : icon)
                .foregroundColor(isCurrent ? .blue : iconColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(record.title)
                        .font(isCurrent ? .headline : .body)
                        .fontWeight(isCurrent ? .bold : .regular)
                        .lineLimit(1)

                    if let siteType = record.siteType {
                        Text("[\(siteType)]")
                            .font(.caption2).foregroundColor(.orange)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.1)).cornerRadius(4)
                    }

                    if record.navigationType != .normal {
                        Text(record.navigationType.rawValue)
                            .font(.caption2).foregroundColor(iconColor)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(iconColor.opacity(0.1)).cornerRadius(4)
                    }
                    Spacer()
                }

                Text(record.url.absoluteString).font(.caption).foregroundColor(.gray).lineLimit(1)

                HStack {
                    Text("ID: \(String(record.id.uuidString.prefix(8)))").font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    Text(DateFormatter.shortTime.string(from: record.timestamp)).font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .background(isCurrent ? Color.blue.opacity(0.1) : Color.clear)
        .cornerRadius(8)
    }
}

extension DateFormatter {
    static let shortTime: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()
}
