//
//  Site Menu UI.swift
//  🧩 사이트 메뉴 시스템 - UI 컴포넌트 모음 (압축 최적화)
//  📋 공통 레이아웃 래퍼로 VStack 중복 제거
//  🎯 코드 줄 수 대폭 감소 (기존 대비 ~40% 단축)
//  🚫 팝업 차단 UI 텍스트 및 동기화 수정
//

import SwiftUI
import Foundation
import WebKit
import AVFoundation

// MARK: - 🎯 공통 레이아웃 래퍼 (VStack 완전 대체)
struct VLayout<Content: View>: View {
    let spacing: CGFloat
    let alignment: HorizontalAlignment
    let content: Content
    
    init(spacing: CGFloat = 0, alignment: HorizontalAlignment = .center, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.alignment = alignment
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: alignment, spacing: spacing) { content }
    }
}

struct HLayout<Content: View>: View {
    let spacing: CGFloat
    let alignment: VerticalAlignment
    let content: Content
    
    init(spacing: CGFloat = 0, alignment: VerticalAlignment = .center, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.alignment = alignment
        self.content = content()
    }
    
    var body: some View {
        HStack(alignment: alignment, spacing: spacing) { content }
    }
}

// MARK: - 🎯 컴팩트 텍스트 뷰 (Text + 속성 한줄화)
struct CompactText: View {
    let text: String
    let font: Font
    let color: Color
    let lineLimit: Int?
    
    init(_ text: String, _ font: Font = .body, _ color: Color = .primary, lines: Int? = nil) {
        self.text = text
        self.font = font
        self.color = color
        self.lineLimit = lines
    }
    
    var body: some View {
        if let limit = lineLimit {
            Text(text).font(font).foregroundColor(color).lineLimit(limit)
        } else {
            Text(text).font(font).foregroundColor(color)
        }
    }
}

// MARK: - 🎯 컴팩트 아이콘 뷰
struct Icon: View {
    let name: String
    let size: CGFloat
    let color: Color
    
    init(_ name: String, _ size: CGFloat = 20, _ color: Color = .primary) {
        self.name = name
        self.size = size
        self.color = color
    }
    
    var body: some View {
        Image(systemName: name).font(.system(size: size)).foregroundColor(color).frame(width: size + 4)
    }
}

// MARK: - 🎨 UI Components Module
extension SiteMenuSystem {
    enum UI {
        
        // MARK: - 🚫 Popup Block Alert View (수정됨 - 허용/차단으로 변경)
        struct PopupBlockedAlert: View {
            let domain: String
            let blockedCount: Int
            @Binding var isPresented: Bool
            
            var body: some View {
                VLayout(spacing: 16) {
                    Icon("shield.fill", 48, .red)
                    CompactText("팝업 차단됨", .title2.bold(), .primary)
                    
                    VLayout(spacing: 8) {
                        CompactText("\(domain)에서 팝업을 차단했습니다", .body, .primary).multilineTextAlignment(.center)
                        if blockedCount > 1 {
                            CompactText("총 \(blockedCount)개의 팝업이 차단되었습니다", .caption, .secondary)
                        }
                    }
                    
                    VLayout(spacing: 8) {
                        HLayout(spacing: 12) {
                            Button("허용") { 
                                PopupBlockManager.shared.allowPopupsForDomain(domain)
                                // 🚫 즉시 상태 동기화를 위한 알림 추가
                                NotificationCenter.default.post(name: .popupDomainAllowListChanged, object: nil)
                                isPresented = false 
                            }
                            .foregroundColor(.green).frame(maxWidth: .infinity)
                            Button("차단") { isPresented = false }
                                .foregroundColor(.red).frame(maxWidth: .infinity)
                        }
                        Button("팝업 차단 끄기") { 
                            PopupBlockManager.shared.isPopupBlocked = false
                            isPresented = false 
                        }
                        .font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(24)
                .background(Color(.systemBackground))
                .cornerRadius(16)
                .shadow(radius: 20)
                .frame(maxWidth: 300)
            }
        }
        
        // MARK: - Main Site Menu Overlay (압축)
        struct SiteMenuOverlay: View {
            @ObservedObject var manager: SiteMenuManager
            let currentState: WebViewStateModel
            let outerHorizontalPadding: CGFloat
            let showAddressBar: Bool
            let whiteGlassBackground: AnyView
            let whiteGlassOverlay: AnyView
            @Binding var tabs: [WebTab]
            @Binding var selectedTabIndex: Int

            var body: some View {
                ZStack {
                    Color.black.opacity(0.1).ignoresSafeArea().onTapGesture { manager.showSiteMenu = false }
                    
                    VStack(spacing: 0) {
                        Spacer()
                        siteMenuContent
                            .background(whiteGlassBackground)
                            .overlay(whiteGlassOverlay)
                            .padding(.horizontal, outerHorizontalPadding)
                            .padding(.bottom, 10)
                        Spacer().frame(height: showAddressBar ? 160 : 110)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: manager.showSiteMenu)
            }

            @ViewBuilder
            private var siteMenuContent: some View {
                VLayout(spacing: 0) {
                    siteInfoSection
                    Divider().padding(.vertical, 8)
                    quickSettingsSection
                    Divider().padding(.vertical, 8)
                    menuOptionsSection
                    Divider().padding(.vertical, 8)
                    downloadsSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            @ViewBuilder
            private var siteInfoSection: some View {
                HLayout {
                    VLayout(spacing: 4, alignment: .leading) {
                        HLayout {
                            let info = SiteMenuSystem.Settings.getSiteSecurityInfo(for: currentState.currentURL)
                            Icon(info.icon, 20, info.color)
                            CompactText(info.text, .headline, info.color)
                            if SiteMenuSystem.Settings.getPopupBlockedCount() > 0 {
                                CompactText("(\(SiteMenuSystem.Settings.getPopupBlockedCount())개 차단됨)", .caption, .red)
                            }
                        }
                        if let url = currentState.currentURL {
                            CompactText(url.host ?? url.absoluteString, .caption, .secondary, lines: 1)
                        }
                    }
                    Spacer()
                }
            }
            
            @ViewBuilder
            private var quickSettingsSection: some View {
                VLayout(spacing: 8) {
                    HLayout {
                        quickButton("shield.fill", "팝업 차단", manager.popupBlocked, manager.popupBlocked ? .blue : .gray) { manager.togglePopupBlocking() }
                        quickButton("speedometer", "성능", false, .red) { manager.showPerformanceSettings = true }
                    }
                    
                    VLayout(spacing: 8) {
                        Button(action: { manager.toggleDesktopMode() }) {
                            HLayout(spacing: 8) {
                                Icon(manager.getDesktopModeEnabled() ? "display" : "iphone", 28, manager.getDesktopModeEnabled() ? .blue : .gray)
                                CompactText("데스크탑 모드", .headline, manager.getDesktopModeEnabled() ? .primary : .secondary)
                                Spacer()
                                Text(manager.getDesktopModeEnabled() ? "ON" : "OFF")
                                    .font(.caption).fontWeight(.semibold)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(manager.getDesktopModeEnabled() ? Color.blue : Color.gray)
                                    .foregroundColor(.white).cornerRadius(12)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .background(manager.getDesktopModeEnabled() ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1))
                            .cornerRadius(12)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(manager.getDesktopModeEnabled() ? Color.blue.opacity(0.3) : Color.gray.opacity(0.2), lineWidth: 1))
                        }.buttonStyle(.plain)
                        
                        if manager.getDesktopModeEnabled() { desktopZoomControls }
                    }
                }
            }
            
            @ViewBuilder
            private func quickButton(_ icon: String, _ title: String, _ isOn: Bool, _ color: Color, action: @escaping () -> Void) -> some View {
                Button(action: action) {
                    VLayout(spacing: 4) {
                        Icon(icon, 28, color)
                        CompactText(title, .caption, isOn ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(isOn ? color.opacity(0.1) : Color.clear)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(isOn ? color.opacity(0.3) : Color.gray.opacity(0.2), lineWidth: 1))
                }.buttonStyle(.plain)
            }
            
            @ViewBuilder
            private var desktopZoomControls: some View {
                VLayout(spacing: 12) {
                    HLayout {
                        CompactText("페이지 배율", .subheadline.weight(.medium), .primary)
                        Spacer()
                        Text("\(String(format: "%.0f", manager.getZoomLevel() * 100))%")
                            .font(.subheadline).fontWeight(.bold).foregroundColor(.blue)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.blue.opacity(0.1)).cornerRadius(8)
                    }
                    
                    VLayout(spacing: 8) {
                        HLayout(spacing: 12) {
                            CompactText("30%", .caption2, .secondary)
                            Slider(value: Binding(
                                get: { manager.getZoomLevel() },
                                set: { manager.setZoomLevel($0) }
                            ), in: 0.3...3.0, step: 0.1).accentColor(.blue)
                            CompactText("300%", .caption2, .secondary)
                        }
                        
                        HLayout(spacing: 8) {
                            zoomButton("-") { manager.adjustZoom(-0.1) }
                            Spacer()
                            Button("리셋") { manager.setZoomLevel(1.0); UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                                .font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Color.gray.opacity(0.1)).foregroundColor(.primary).cornerRadius(8)
                            Spacer()
                            zoomButton("+") { manager.adjustZoom(0.1) }
                        }
                    }
                    
                    VLayout(spacing: 8) {
                        CompactText("빠른 배율 선택", .caption, .secondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                            ForEach(SiteMenuSystem.Desktop.getZoomPresets(), id: \.self) { preset in
                                Button("\(String(format: "%.0f", preset * 100))%") {
                                    manager.setZoomLevel(preset)
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }
                                .font(.caption).padding(.horizontal, 8).padding(.vertical, 6)
                                .background(abs(manager.getZoomLevel() - preset) < 0.05 ? Color.blue : Color.gray.opacity(0.2))
                                .foregroundColor(abs(manager.getZoomLevel() - preset) < 0.05 ? .white : .primary)
                                .cornerRadius(8)
                            }
                        }
                    }
                }
                .padding(.top, 8).padding(.horizontal, 8).padding(.vertical, 12)
                .background(Color.blue.opacity(0.05)).cornerRadius(12)
            }
            
            @ViewBuilder
            private func zoomButton(_ text: String, action: @escaping () -> Void) -> some View {
                Button(text) { action(); UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                    .frame(width: 32, height: 32)
                    .background(Color.blue.opacity(0.1)).foregroundColor(.blue).cornerRadius(8)
            }

            @ViewBuilder
            private var menuOptionsSection: some View {
                HLayout {
                    menuOption("line.3.horizontal.decrease.circle", "방문 기록 관리", "\(manager.historyFilters.count)개 필터", .orange) { manager.showHistoryFilterManager = true }
                    Spacer()
                    menuOption("shield.lefthalf.filled", "개인정보", "쿠키 & 캐시", .purple) { manager.showPrivacySettings = true }
                }
            }
            
            @ViewBuilder
            private func menuOption(_ icon: String, _ title: String, _ subtitle: String, _ color: Color, action: @escaping () -> Void) -> some View {
                Button(action: action) {
                    VLayout(spacing: 4) {
                        Icon(icon, 28, color)
                        CompactText(title, .caption.weight(.medium), .primary)
                        CompactText(subtitle, .caption2, .secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Color.gray.opacity(0.05)).cornerRadius(8)
                }.buttonStyle(.plain)
            }

            @ViewBuilder
            private var downloadsSection: some View {
                VLayout(spacing: 8, alignment: .leading) {
                    HLayout {
                        Button(action: { manager.showDownloadsList = true }) {
                            HLayout(spacing: 8) {
                                Icon("arrow.down.circle.fill", 20, .blue)
                                CompactText("다운로드", .headline, .primary)
                                Icon("chevron.right", 12, .secondary)
                            }
                        }.buttonStyle(.plain)
                        Spacer()
                        if !manager.downloads.isEmpty {
                            Text("\(manager.downloads.count)개").font(.caption).foregroundColor(.secondary)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.blue.opacity(0.1)).cornerRadius(12)
                        }
                    }

                    if !manager.downloads.isEmpty {
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(Array(manager.downloads.prefix(3))) { download in
                                    downloadRow(download)
                                }
                                if manager.downloads.count > 3 {
                                    HLayout { Spacer(); CompactText("및 \(manager.downloads.count - 3)개 더...", .caption, .secondary); Spacer() }
                                        .padding(.vertical, 4)
                                }
                            }
                        }.frame(maxHeight: 100)
                    } else {
                        HLayout {
                            Spacer()
                            VLayout(spacing: 4) {
                                Icon("tray", 24, .secondary.opacity(0.6))
                                CompactText("다운로드된 파일이 없습니다", .caption, .secondary).multilineTextAlignment(.center)
                            }
                            Spacer()
                        }.padding(.vertical, 16)
                    }
                }
            }

            @ViewBuilder
            private func downloadRow(_ download: DownloadItem) -> some View {
                HLayout {
                    Icon("doc.fill", 16, .blue)
                    VLayout(spacing: 2, alignment: .leading) {
                        CompactText(download.filename, .system(size: 14, weight: .medium), .primary, lines: 1)
                        HLayout {
                            CompactText(download.size, .caption, .secondary)
                            Spacer()
                            CompactText(RelativeDateTimeFormatter().localizedString(for: download.date, relativeTo: Date()), .caption, .secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 4).padding(.horizontal, 8)
                .background(Color.white.opacity(0.95)).cornerRadius(8)
            }
        }
        
        // MARK: - Recent Visits View (압축)
        struct RecentVisitsView: View {
            @ObservedObject var manager: SiteMenuManager
            let onURLSelected: (URL) -> Void
            let onManageHistory: () -> Void

            var body: some View {
                VLayout(spacing: 0) {
                    if manager.recentVisits.isEmpty {
                        VLayout(spacing: 12) {
                            Icon("clock.arrow.circlepath", 28, .secondary)
                            CompactText("최근 방문한 사이트가 없습니다", .subheadline, .secondary).multilineTextAlignment(.center)
                        }.padding(.vertical, 20)
                    } else {
                        VLayout(spacing: 0) {
                            ForEach(manager.recentVisits) { entry in
                                historyRow(entry)
                                if entry.id != manager.recentVisits.last?.id {
                                    Divider().padding(.horizontal, 14)
                                }
                            }
                        }
                    }
                }
            }

            @ViewBuilder
            private func historyRow(_ entry: HistoryEntry) -> some View {
                Button(action: { onURLSelected(entry.url); }) {
                    HLayout(spacing: 12) {
                        Icon("clock", 16, .blue)
                        VLayout(spacing: 2, alignment: .leading) {
                            CompactText(entry.title, .system(size: 16, weight: .medium), .primary, lines: 1)
                            CompactText(entry.url.absoluteString, .system(size: 14), .secondary, lines: 1)
                        }
                        Spacer()
                        CompactText(RelativeDateTimeFormatter().localizedString(for: entry.date, relativeTo: Date()), .caption, .secondary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        
        // MARK: - Autocomplete View (압축)
        struct AutocompleteView: View {
            @ObservedObject var manager: SiteMenuManager
            let searchText: String
            let onURLSelected: (URL) -> Void
            let onManageHistory: () -> Void

            var body: some View {
                VLayout(spacing: 0) {
                    if manager.getAutocompleteEntries(for: searchText).isEmpty {
                        VLayout(spacing: 12) {
                            Icon("magnifyingglass", 28, .secondary)
                            CompactText("'\(searchText)'에 대한 방문 기록이 없습니다", .subheadline, .secondary).multilineTextAlignment(.center)
                        }.padding(.vertical, 20)
                    } else {
                        VLayout(spacing: 0) {
                            ForEach(manager.getAutocompleteEntries(for: searchText)) { entry in
                                autocompleteRow(entry)
                                if entry.id != manager.getAutocompleteEntries(for: searchText).last?.id {
                                    Divider().padding(.horizontal, 14)
                                }
                            }
                        }
                    }
                }
            }

            @ViewBuilder
            private func autocompleteRow(_ entry: HistoryEntry) -> some View {
                Button(action: { onURLSelected(entry.url) }) {
                    HLayout(spacing: 12) {
                        Icon("magnifyingglass", 20, .gray)
                        VLayout(spacing: 2, alignment: .leading) {
                            highlightedText(entry.title, searchText: searchText).font(.system(size: 16, weight: .medium)).lineLimit(1)
                            highlightedText(entry.url.absoluteString, searchText: searchText).font(.system(size: 14)).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Icon("arrow.up.left", 12, .secondary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }

            @ViewBuilder
            private func highlightedText(_ text: String, searchText: String) -> some View {
                let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    Text(text).foregroundColor(.primary)
                } else {
                    let parts = text.components(separatedBy: trimmed)
                    if parts.count > 1 {
                        HLayout(spacing: 0) {
                            ForEach(0..<parts.count, id: \.self) { index in
                                Text(parts[index]).foregroundColor(.primary)
                                if index < parts.count - 1 {
                                    Text(trimmed).foregroundColor(.blue).fontWeight(.semibold)
                                }
                            }
                        }
                    } else {
                        Text(text).foregroundColor(.primary)
                    }
                }
            }
        }
        
        // MARK: - Downloads List View (압축)
        struct DownloadsListView: View {
            @ObservedObject var manager: SiteMenuManager
            @State private var searchText = ""
            @State private var showClearAllAlert = false
            @Environment(\.dismiss) private var dismiss

            private var filteredDownloads: [DownloadItem] {
                searchText.isEmpty ? manager.downloads : manager.downloads.filter { $0.filename.localizedCaseInsensitiveContains(searchText) }
            }

            var body: some View {
                List {
                    if filteredDownloads.isEmpty {
                        VLayout(spacing: 16) {
                            Icon("arrow.down.circle", 48, .secondary)
                            CompactText(searchText.isEmpty ? "다운로드된 파일이 없습니다" : "검색 결과가 없습니다", .title3, .secondary)
                            if searchText.isEmpty {
                                CompactText("웹에서 파일을 다운로드하면 여기에 표시됩니다\n(앱 내부 Documents/Downloads 폴더)", .caption, .secondary).multilineTextAlignment(.center)
                            }
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 60)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    } else {
                        ForEach(filteredDownloads) { download in
                            DownloadListRow(download: download, manager: manager)
                        }.onDelete(perform: deleteDownloads)
                    }
                }
                .navigationTitle("다운로드").navigationBarTitleDisplayMode(.large)
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) { Button("닫기") { dismiss() } }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            if !manager.downloads.isEmpty {
                                Button(role: .destructive) { showClearAllAlert = true } label: { Label("모든 파일 실제 삭제", systemImage: "trash.fill") }
                                Button { manager.clearDownloads() } label: { Label("목록만 지우기", systemImage: "list.dash") }
                            }
                            Button { openDownloadsFolder() } label: { Label("파일 앱에서 열기", systemImage: "folder") }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
                .alert("모든 다운로드 파일 삭제", isPresented: $showClearAllAlert) {
                    Button("취소", role: .cancel) { }
                    Button("실제 파일 삭제", role: .destructive) { manager.clearAllDownloadFiles() }
                } message: {
                    Text("다운로드 폴더의 모든 파일을 실제로 삭제하시겠습니까?\n이 작업은 되돌릴 수 없습니다.")
                }
            }

            private func deleteDownloads(at offsets: IndexSet) {
                for index in offsets {
                    manager.deleteDownloadFile(filteredDownloads[index])
                }
            }

            private func openDownloadsFolder() {
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let downloadsPath = documentsPath.appendingPathComponent("Downloads", isDirectory: true)
                if let topVC = getTopViewController() {
                    let activityVC = UIActivityViewController(activityItems: [downloadsPath], applicationActivities: nil)
                    activityVC.popoverPresentationController?.sourceView = topVC.view
                    topVC.present(activityVC, animated: true)
                }
            }
        }
        
        // MARK: - Download List Row (압축)
        struct DownloadListRow: View {
            let download: DownloadItem
            @ObservedObject var manager: SiteMenuManager

            private var fileExtension: String {
                URL(fileURLWithPath: download.filename).pathExtension.lowercased()
            }

            private var fileIcon: String {
                switch fileExtension {
                case "pdf": return "doc.richtext"
                case "jpg", "jpeg", "png", "gif", "webp": return "photo"
                case "mp4", "mov", "avi", "mkv": return "video"
                case "mp3", "wav", "aac", "flac": return "music.note"
                case "zip", "rar", "7z": return "archivebox"
                case "txt", "md": return "doc.text"
                case "html", "htm": return "globe"
                default: return "doc"
                }
            }

            private var fileIconColor: Color {
                switch fileExtension {
                case "pdf": return .red
                case "jpg", "jpeg", "png", "gif", "webp": return .green
                case "mp4", "mov", "avi", "mkv": return .purple
                case "mp3", "wav", "aac", "flac": return .orange
                case "zip", "rar", "7z": return .yellow
                case "txt", "md": return .blue
                case "html", "htm": return .cyan
                default: return .gray
                }
            }

            var body: some View {
                HLayout(spacing: 12) {
                    Image(systemName: fileIcon).font(.title2).foregroundColor(fileIconColor)
                        .frame(width: 40, height: 40)
                        .background(fileIconColor.opacity(0.1)).cornerRadius(8)

                    VLayout(spacing: 4, alignment: .leading) {
                        CompactText(download.filename, .headline, .primary, lines: 2)
                        HLayout {
                            CompactText(download.size, .caption, .secondary)
                            Spacer()
                            CompactText(RelativeDateTimeFormatter().localizedString(for: download.date, relativeTo: Date()), .caption, .secondary)
                            if let fileURL = download.fileURL {
                                Icon(FileManager.default.fileExists(atPath: fileURL.path) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", 
                                     12, FileManager.default.fileExists(atPath: fileURL.path) ? .green : .orange)
                            }
                        }
                    }
                    Spacer()
                    
                    Menu {
                        if let fileURL = download.fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                            Button { openFile(fileURL) } label: { Label("열기", systemImage: "doc.text") }
                            Button { shareFile(fileURL) } label: { Label("공유", systemImage: "square.and.arrow.up") }
                            Divider()
                            Button(role: .destructive) { manager.deleteDownloadFile(download) } label: { Label("실제 파일 삭제", systemImage: "trash.fill") }
                        } else {
                            Text("파일이 존재하지 않음").foregroundColor(.secondary)
                        }
                        Button(role: .destructive) { manager.removeDownload(download) } label: { Label("목록에서만 제거", systemImage: "list.dash") }
                    } label: {
                        Icon("ellipsis.circle", 24, .secondary)
                    }.buttonStyle(.plain)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if let fileURL = download.fileURL, FileManager.default.fileExists(atPath: fileURL.path) { openFile(fileURL) }
                }
            }

            private func openFile(_ fileURL: URL) {
                if let topVC = getTopViewController() {
                    let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
                    activityVC.popoverPresentationController?.sourceView = topVC.view
                    topVC.present(activityVC, animated: true)
                }
            }

            private func shareFile(_ fileURL: URL) {
                if let topVC = getTopViewController() {
                    let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
                    activityVC.popoverPresentationController?.sourceView = topVC.view
                    topVC.present(activityVC, animated: true)
                }
            }
        }
        
        // MARK: - History Filter Manager View (압축)
        struct HistoryFilterManagerView: View {
            @ObservedObject var manager: SiteMenuManager
            @Environment(\.dismiss) private var dismiss
            @State private var showAddFilterSheet = false
            @State private var newFilterType: HistoryFilter.FilterType = .keyword
            @State private var newFilterValue = ""
            @State private var showClearAllAlert = false
            @State private var editingFilter: HistoryFilter?
            @State private var editingValue = ""

            private var keywordFilters: [HistoryFilter] { manager.historyFilters.filter { $0.type == .keyword } }
            private var domainFilters: [HistoryFilter] { manager.historyFilters.filter { $0.type == .domain } }

            var body: some View {
                List {
                    Section {
                        Toggle("방문 기록 필터링", isOn: $manager.isHistoryFilteringEnabled).font(.headline)
                    } header: { Text("필터 설정") } footer: {
                        Text("필터링을 켜면 설정한 키워드나 도메인이 포함된 방문 기록이 주소창 자동완성에서 숨겨집니다.")
                    }

                    if manager.isHistoryFilteringEnabled && !manager.historyFilters.isEmpty {
                        Section("현재 필터 상태") {
                            let enabledCount = manager.historyFilters.filter { $0.isEnabled }.count
                            HLayout {
                                Icon("line.3.horizontal.decrease.circle", 20, .blue)
                                CompactText("활성 필터: \(enabledCount) / \(manager.historyFilters.count)개", .subheadline, .primary)
                                Spacer()
                                if enabledCount > 0 {
                                    Text("적용 중").font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Color.blue.opacity(0.1)).foregroundColor(.blue).cornerRadius(8)
                                }
                            }
                        }
                    }

                    if !keywordFilters.isEmpty {
                        Section("키워드 필터") {
                            ForEach(keywordFilters) { filter in filterRow(filter) }
                                .onDelete { offsets in
                                    for index in offsets { manager.removeHistoryFilter(keywordFilters[index]) }
                                }
                        }
                    }

                    if !domainFilters.isEmpty {
                        Section("도메인 필터") {
                            ForEach(domainFilters) { filter in filterRow(filter) }
                                .onDelete { offsets in
                                    for index in offsets { manager.removeHistoryFilter(domainFilters[index]) }
                                }
                        }
                    }

                    if manager.historyFilters.isEmpty {
                        Section {
                            VLayout(spacing: 16) {
                                Icon("line.3.horizontal.decrease.circle", 48, .secondary)
                                VLayout(spacing: 8) {
                                    CompactText("설정된 필터가 없습니다", .headline, .secondary)
                                    CompactText("키워드나 도메인 필터를 추가하여\n원하지 않는 방문 기록을 숨길 수 있습니다", .subheadline, .secondary).multilineTextAlignment(.center)
                                }
                            }.frame(maxWidth: .infinity).padding(.vertical, 20)
                        }.listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                }
                .navigationTitle("방문 기록 관리").navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) { Button("닫기") { dismiss() } }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button { showAddFilterSheet = true } label: { Label("필터 추가", systemImage: "plus") }
                            if !manager.historyFilters.isEmpty {
                                Divider()
                                Button(role: .destructive) { showClearAllAlert = true } label: { Label("모든 필터 삭제", systemImage: "trash") }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
                .sheet(isPresented: $showAddFilterSheet) { addFilterSheet }
                .alert("필터 수정", isPresented: Binding(
                    get: { editingFilter != nil },
                    set: { if !$0 { editingFilter = nil } }
                )) {
                    TextField("필터 값", text: $editingValue)
                    Button("취소", role: .cancel) { editingFilter = nil; editingValue = "" }
                    Button("저장") {
                        if let filter = editingFilter { manager.updateHistoryFilter(filter, newValue: editingValue) }
                        editingFilter = nil; editingValue = ""
                    }
                } message: {
                    if let filter = editingFilter { Text("\(filter.type.displayName) 필터를 수정하세요") }
                }
                .alert("모든 필터 삭제", isPresented: $showClearAllAlert) {
                    Button("취소", role: .cancel) { }
                    Button("삭제", role: .destructive) { manager.clearAllHistoryFilters() }
                } message: { Text("모든 히스토리 필터를 삭제하시겠습니까?") }
            }

            @ViewBuilder
            private func filterRow(_ filter: HistoryFilter) -> some View {
                HLayout {
                    Icon(filter.type.icon, 24, filter.isEnabled ? .blue : .gray)
                    VLayout(spacing: 2, alignment: .leading) {
                        CompactText(filter.value, .headline, filter.isEnabled ? .primary : .secondary)
                        HLayout {
                            CompactText(filter.type.displayName, .caption, .secondary)
                            CompactText("• \(filter.isEnabled ? "활성" : "비활성")", .caption, filter.isEnabled ? .blue : .gray)
                            Spacer()
                            CompactText(RelativeDateTimeFormatter().localizedString(for: filter.createdAt, relativeTo: Date()), .caption2, .secondary)
                        }
                    }
                    Spacer()
                    Menu {
                        Button { editingFilter = filter; editingValue = filter.value } label: { Label("수정", systemImage: "pencil") }
                        Button(role: .destructive) { manager.removeHistoryFilter(filter) } label: { Label("삭제", systemImage: "trash") }
                    } label: { Icon("ellipsis", 20, .secondary) }
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { manager.toggleHistoryFilter(filter) } }
            }

            @ViewBuilder
            private var addFilterSheet: some View {
                NavigationView {
                    Form {
                        Section("필터 종류") {
                            Picker("필터 종류", selection: $newFilterType) {
                                ForEach(HistoryFilter.FilterType.allCases, id: \.self) { type in
                                    HLayout { Icon(type.icon, 16, .primary); Text(type.displayName) }.tag(type)
                                }
                            }.pickerStyle(.segmented)
                        }

                        Section {
                            TextField(placeholderText, text: $newFilterValue).autocapitalization(.none).disableAutocorrection(true)
                        } header: { Text("\(newFilterType.displayName) 입력") } footer: { Text(footerText) }

                        if !newFilterValue.isEmpty {
                            Section("미리보기") {
                                HLayout {
                                    Icon(newFilterType.icon, 20, .blue)
                                    CompactText(newFilterValue.lowercased(), .headline, .primary)
                                    Spacer()
                                    Text("필터됨").font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Color.red.opacity(0.1)).foregroundColor(.red).cornerRadius(8)
                                }
                            }
                        }
                    }
                    .navigationTitle("필터 추가").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("취소") { showAddFilterSheet = false; resetAddFilterForm() }
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("추가") {
                                manager.addHistoryFilter(type: newFilterType, value: newFilterValue)
                                showAddFilterSheet = false; resetAddFilterForm()
                            }.disabled(newFilterValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }

            private var placeholderText: String {
                switch newFilterType {
                case .keyword: return "예: 광고, 스팸, 성인"
                case .domain: return "예: example.com, ads.google.com"
                }
            }

            private var footerText: String {
                switch newFilterType {
                case .keyword: return "페이지 제목이나 URL에 이 키워드가 포함된 방문 기록이 숨겨집니다."
                case .domain: return "이 도메인의 방문 기록이 숨겨집니다. 정확한 도메인명을 입력하세요."
                }
            }

            private func resetAddFilterForm() {
                newFilterType = .keyword; newFilterValue = ""
            }
        }
        
        // MARK: - Privacy Settings View (압축)
        struct PrivacySettingsView: View {
            @ObservedObject var manager: SiteMenuManager
            @Environment(\.dismiss) private var dismiss
            @State private var showClearCookiesAlert = false
            @State private var showClearCacheAlert = false
            @State private var showClearAllDataAlert = false
            @State private var showPopupDomainManager = false
            
            var body: some View {
                List {
                    Section("쿠키 및 사이트 데이터") {
                        privacyRow("모든 쿠키 삭제", "로그인 상태가 해제됩니다", .red) { showClearCookiesAlert = true }
                        privacyRow("캐시 삭제", "이미지 및 파일 캐시를 삭제합니다", .red) { showClearCacheAlert = true }
                        privacyRow("모든 웹사이트 데이터 삭제", "쿠키, 캐시, 로컬 저장소 등 모든 데이터", .red, bold: true) { showClearAllDataAlert = true }
                    }
                    
                    Section("팝업 차단") {
                        HLayout {
                            CompactText("차단된 팝업 수", .headline, .primary)
                            Spacer()
                            CompactText("\(SiteMenuSystem.Settings.getPopupBlockedCount())개", .body, .secondary)
                            Button("초기화") { SiteMenuSystem.Settings.resetPopupBlockedCount() }.font(.caption)
                        }
                        
                        HLayout {
                            VLayout(alignment: .leading) {
                                CompactText("도메인별 설정 관리", .headline, .primary)
                                CompactText("사이트별 팝업 차단/허용 설정", .caption, .secondary)
                            }
                            Spacer()
                            CompactText("\(PopupBlockManager.shared.getAllowedDomains().count)개 허용", .body, .secondary)
                            Button("관리") { showPopupDomainManager = true }.foregroundColor(.blue)
                        }
                    }
                }
                .navigationTitle("개인정보 보호").navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) { Button("닫기") { dismiss() } }
                }
                .sheet(isPresented: $showPopupDomainManager) {
                    NavigationView { PopupDomainManagerView() }
                }
                .alert("쿠키 삭제", isPresented: $showClearCookiesAlert) {
                    Button("취소", role: .cancel) { }
                    Button("삭제", role: .destructive) { SiteMenuSystem.Settings.clearAllCookies() }
                } message: { Text("모든 웹사이트의 쿠키를 삭제하시겠습니까? 모든 사이트에서 로그아웃됩니다.") }
                .alert("캐시 삭제", isPresented: $showClearCacheAlert) {
                    Button("취소", role: .cancel) { }
                    Button("삭제", role: .destructive) { SiteMenuSystem.Settings.clearCache() }
                } message: { Text("모든 캐시를 삭제하시겠습니까? 페이지 로딩이 일시적으로 느려질 수 있습니다.") }
                .alert("모든 웹사이트 데이터 삭제", isPresented: $showClearAllDataAlert) {
                    Button("취소", role: .cancel) { }
                    Button("모두 삭제", role: .destructive) { SiteMenuSystem.Settings.clearWebsiteData() }
                } message: { Text("쿠키, 캐시, 로컬 저장소 등 모든 웹사이트 데이터를 삭제하시겠습니까? 이 작업은 되돌릴 수 없습니다.") }
            }
            
            @ViewBuilder
            private func privacyRow(_ title: String, _ subtitle: String, _ buttonColor: Color, bold: Bool = false, action: @escaping () -> Void) -> some View {
                HLayout {
                    VLayout(alignment: .leading) {
                        CompactText(title, .headline, .primary)
                        CompactText(subtitle, .caption, .secondary)
                    }
                    Spacer()
                    Button(bold ? "모두 삭제" : "삭제") { action() }
                        .foregroundColor(buttonColor)
                        .fontWeight(bold ? .semibold : .regular)
                }
            }
        }
        
        // MARK: - 🚫 Popup Domain Manager View (수정됨 - 동기화 개선)
        struct PopupDomainManagerView: View {
            @Environment(\.dismiss) private var dismiss
            @State private var allowedDomains: [String] = []
            @State private var recentBlockedPopups: [PopupBlockManager.BlockedPopup] = []
            @State private var showAddDomainAlert = false
            @State private var newDomainText = ""
            @State private var showClearAllAllowedAlert = false
            
            var body: some View {
                List {
                    Section {
                        if allowedDomains.isEmpty {
                            VLayout(spacing: 12) {
                                Icon("shield.checkered", 28, .secondary)
                                CompactText("허용된 사이트가 없습니다", .subheadline, .secondary)
                                CompactText("특정 사이트의 팝업을 허용하려면\n해당 사이트에서 팝업 차단 알림이 나타날 때\n'허용' 버튼을 누르세요", .caption, .secondary).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity).padding(.vertical, 20).listRowBackground(Color.clear).listRowSeparator(.hidden)
                        } else {
                            ForEach(allowedDomains, id: \.self) { domain in
                                HLayout {
                                    Icon("checkmark.shield.fill", 24, .green)
                                    VLayout(spacing: 2, alignment: .leading) {
                                        CompactText(domain, .headline, .primary)
                                        CompactText("팝업 허용됨", .caption, .green)
                                    }
                                    Spacer()
                                    Button("차단") { 
                                        PopupBlockManager.shared.removeAllowedDomain(domain)
                                        refreshData()
                                        // 🚫 도메인 목록 변경 알림 전송
                                        NotificationCenter.default.post(name: .popupDomainAllowListChanged, object: nil)
                                    }
                                    .font(.caption).foregroundColor(.red).padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.red.opacity(0.1)).cornerRadius(8)
                                }
                            }
                        }
                    } header: {
                        HLayout {
                            Text("팝업 허용 사이트 (\(allowedDomains.count)개)")
                            Spacer()
                            if !allowedDomains.isEmpty {
                                Button("수동 추가") { showAddDomainAlert = true }.font(.caption).foregroundColor(.blue)
                            }
                        }
                    }
                    
                    Section {
                        if recentBlockedPopups.isEmpty {
                            VLayout(spacing: 12) {
                                Icon("shield.fill", 28, .secondary)
                                CompactText("차단된 팝업이 없습니다", .subheadline, .secondary)
                            }.frame(maxWidth: .infinity).padding(.vertical, 20).listRowBackground(Color.clear).listRowSeparator(.hidden)
                        } else {
                            ForEach(recentBlockedPopups.indices, id: \.self) { index in
                                let popup = recentBlockedPopups[index]
                                HLayout {
                                    Icon("shield.slash.fill", 24, .red)
                                    VLayout(spacing: 2, alignment: .leading) {
                                        CompactText(popup.domain, .headline, .primary)
                                        if !popup.url.isEmpty { CompactText(popup.url, .caption, .secondary, lines: 1) }
                                        CompactText(RelativeDateTimeFormatter().localizedString(for: popup.date, relativeTo: Date()), .caption2, .secondary)
                                    }
                                    Spacer()
                                    Button("허용") { 
                                        PopupBlockManager.shared.allowPopupsForDomain(popup.domain)
                                        refreshData()
                                        // 🚫 도메인 목록 변경 알림 전송
                                        NotificationCenter.default.post(name: .popupDomainAllowListChanged, object: nil)
                                    }
                                    .font(.caption).foregroundColor(.green).padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.green.opacity(0.1)).cornerRadius(8)
                                }
                            }
                        }
                    } header: { Text("최근 차단된 팝업 (\(recentBlockedPopups.count)개)") } footer: {
                        if !recentBlockedPopups.isEmpty { Text("차단된 팝업의 사이트를 허용 목록에 추가할 수 있습니다") }
                    }
                }
                .navigationTitle("팝업 차단 관리").navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) { Button("닫기") { dismiss() } }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button { showAddDomainAlert = true } label: { Label("도메인 수동 추가", systemImage: "plus") }
                            if !allowedDomains.isEmpty {
                                Divider()
                                Button(role: .destructive) { showClearAllAllowedAlert = true } label: { Label("모든 허용 사이트 제거", systemImage: "trash") }
                            }
                            Button { SiteMenuSystem.Settings.resetPopupBlockedCount(); refreshData() } label: { Label("차단 기록 초기화", systemImage: "arrow.counterclockwise") }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
                .onAppear { 
                    refreshData()
                    // 🚫 도메인 목록 변경 알림 구독
                    NotificationCenter.default.addObserver(
                        forName: .popupDomainAllowListChanged,
                        object: nil,
                        queue: .main
                    ) { _ in
                        refreshData()
                    }
                }
                .onDisappear {
                    // 🚫 알림 구독 해제
                    NotificationCenter.default.removeObserver(self, name: .popupDomainAllowListChanged, object: nil)
                }
                .alert("도메인 추가", isPresented: $showAddDomainAlert) {
                    TextField("도메인명 (예: example.com)", text: $newDomainText).autocapitalization(.none).disableAutocorrection(true)
                    Button("취소", role: .cancel) { newDomainText = "" }
                    Button("추가") {
                        let trimmedDomain = newDomainText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedDomain.isEmpty { 
                            PopupBlockManager.shared.allowPopupsForDomain(trimmedDomain)
                            refreshData()
                            // 🚫 도메인 목록 변경 알림 전송
                            NotificationCenter.default.post(name: .popupDomainAllowListChanged, object: nil)
                        }
                        newDomainText = ""
                    }.disabled(newDomainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } message: { Text("팝업을 허용할 도메인을 입력하세요") }
                .alert("모든 허용 사이트 제거", isPresented: $showClearAllAllowedAlert) {
                    Button("취소", role: .cancel) { }
                    Button("제거", role: .destructive) {
                        for domain in allowedDomains { PopupBlockManager.shared.removeAllowedDomain(domain) }
                        refreshData()
                        // 🚫 도메인 목록 변경 알림 전송
                        NotificationCenter.default.post(name: .popupDomainAllowListChanged, object: nil)
                    }
                } message: { Text("모든 허용 사이트를 제거하시겠습니까?") }
            }
            
            private func refreshData() {
                allowedDomains = PopupBlockManager.shared.getAllowedDomains()
                recentBlockedPopups = PopupBlockManager.shared.getRecentBlockedPopups(limit: 20)
            }
        }
        
        // MARK: - Performance Settings View (압축)
        struct PerformanceSettingsView: View {
            @ObservedObject var manager: SiteMenuManager
            @Environment(\.dismiss) private var dismiss
            
            var body: some View {
                List {
                    Section("메모리 관리") {
                        let memoryUsage = SiteMenuSystem.Performance.getMemoryUsage()
                        VLayout(spacing: 8, alignment: .leading) {
                            HLayout {
                                CompactText("메모리 사용량", .headline, .primary)
                                Spacer()
                                CompactText("\(String(format: "%.0f", memoryUsage.used)) MB", .body, .secondary)
                            }
                            ProgressView(value: memoryUsage.used / memoryUsage.total)
                                .progressViewStyle(LinearProgressViewStyle(tint: memoryUsage.used / memoryUsage.total > 0.8 ? .red : .blue))
                                .scaleEffect(x: 1, y: 0.5)
                        }
                        
                        HLayout {
                            VLayout(alignment: .leading) {
                                CompactText("웹뷰 풀 정리", .headline, .primary)
                                CompactText("사용하지 않는 웹뷰를 정리합니다", .caption, .secondary)
                            }
                            Spacer()
                            Button("정리") { manager.clearWebViewPool() }.foregroundColor(.blue)
                        }
                    }
                    
                    Section("캐시 설정") {
                        Toggle("이미지 압축", isOn: $manager.imageCompressionEnabled).font(.headline)
                        if manager.imageCompressionEnabled {
                            Text("이미지를 자동으로 압축하여 메모리 사용량을 줄입니다").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    
                    Section("고급 설정") {
                        VLayout(spacing: 8, alignment: .leading) {
                            HLayout {
                                CompactText("메모리 정리 임계값", .headline, .primary)
                                Spacer()
                                CompactText("\(Int(manager.memoryThreshold * 100))%", .body, .secondary)
                            }
                            Slider(value: $manager.memoryThreshold, in: 0.5...0.95, step: 0.05).accentColor(.blue)
                        }
                        
                        VLayout(spacing: 8, alignment: .leading) {
                            HLayout {
                                CompactText("웹뷰 풀 크기", .headline, .primary)
                                Spacer()
                                CompactText("\(manager.webViewPoolSize)개", .body, .secondary)
                            }
                            Slider(value: Binding(
                                get: { Double(manager.webViewPoolSize) },
                                set: { manager.webViewPoolSize = Int($0) }
                            ), in: 5...20, step: 1).accentColor(.blue)
                        }
                    }
                }
                .navigationTitle("성능").navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) { Button("닫기") { dismiss() } }
                }
            }
        }
    }
}

// MARK: - 🚫 새로운 알림 이름 추가
extension Notification.Name {
    static let popupDomainAllowListChanged = Notification.Name("PopupDomainAllowListChanged")
}

// MARK: - 🔧 ContentView Extension (동일)
extension View {
    func siteMenuOverlay(
        manager: SiteMenuManager,
        currentState: WebViewStateModel,
        tabs: Binding<[WebTab]>,
        selectedTabIndex: Binding<Int>,
        outerHorizontalPadding: CGFloat,
        showAddressBar: Bool,
        whiteGlassBackground: AnyView,
        whiteGlassOverlay: AnyView
    ) -> some View {
        self
            .overlay {
                if manager.showSiteMenu {
                    SiteMenuSystem.UI.SiteMenuOverlay(
                        manager: manager,
                        currentState: currentState,
                        outerHorizontalPadding: outerHorizontalPadding,
                        showAddressBar: showAddressBar,
                        whiteGlassBackground: whiteGlassBackground,
                        whiteGlassOverlay: whiteGlassOverlay,
                        tabs: tabs,
                        selectedTabIndex: selectedTabIndex
                    )
                }
            }
            .overlay {
                if manager.showPopupBlockedAlert {
                    Color.black.opacity(0.4).ignoresSafeArea()
                        .overlay {
                            SiteMenuSystem.UI.PopupBlockedAlert(
                                domain: manager.popupAlertDomain,
                                blockedCount: manager.popupAlertCount,
                                isPresented: Binding(
                                    get: { manager.showPopupBlockedAlert },
                                    set: { manager.showPopupBlockedAlert = $0 }
                                )
                            )
                        }
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.3), value: manager.showPopupBlockedAlert)
                }
            }
            .sheet(isPresented: Binding(get: { manager.showDownloadsList }, set: { manager.showDownloadsList = $0 })) {
                NavigationView { SiteMenuSystem.UI.DownloadsListView(manager: manager) }
            }
            .sheet(isPresented: Binding(get: { manager.showHistoryFilterManager }, set: { manager.showHistoryFilterManager = $0 })) {
                NavigationView { SiteMenuSystem.UI.HistoryFilterManagerView(manager: manager) }
            }
            .sheet(isPresented: Binding(get: { manager.showPrivacySettings }, set: { manager.showPrivacySettings = $0 })) {
                NavigationView { SiteMenuSystem.UI.PrivacySettingsView(manager: manager) }
            }
            .sheet(isPresented: Binding(get: { manager.showPerformanceSettings }, set: { manager.showPerformanceSettings = $0 })) {
                NavigationView { SiteMenuSystem.UI.PerformanceSettingsView(manager: manager) }
            }
    }
}
