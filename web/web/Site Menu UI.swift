//
//  Site Menu UI.swift
//  🧩 사이트 메뉴 시스템 - UI 컴포넌트 모음
//  📋 모든 설정 화면 및 오버레이 UI 컴포넌트 - 데스크탑 모드 확장
//

import SwiftUI
import Foundation
import WebKit
import AVFoundation

// MARK: - 🎨 UI Components Module (Complete with Enhanced Popup Blocking and Extended Desktop Mode)
extension SiteMenuSystem {
    enum UI {
        
        // MARK: - 🚫 Popup Block Alert View
        struct PopupBlockedAlert: View {
            let domain: String
            let blockedCount: Int
            @Binding var isPresented: Bool
            
            var body: some View {
                VStack(spacing: 16) {
                    // 아이콘
                    Image(systemName: "shield.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.red)
                    
                    // 제목
                    Text("팝업 차단됨")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    // 메시지
                    VStack(spacing: 8) {
                        Text("\(domain)에서 팝업을 차단했습니다")
                            .font(.body)
                            .multilineTextAlignment(.center)
                        
                        if blockedCount > 1 {
                            Text("총 \(blockedCount)개의 팝업이 차단되었습니다")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // 버튼들
                    VStack(spacing: 8) {
                        HStack(spacing: 12) {
                            Button("이 사이트 허용") {
                                PopupBlockManager.shared.allowPopupsForDomain(domain)
                                isPresented = false
                            }
                            .foregroundColor(.blue)
                            .frame(maxWidth: .infinity)
                            
                            Button("닫기") {
                                isPresented = false
                            }
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity)
                        }
                        
                        Button("팝업 차단 끄기") {
                            PopupBlockManager.shared.isPopupBlocked = false
                            isPresented = false
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }
                .padding(24)
                .background(Color(.systemBackground))
                .cornerRadius(16)
                .shadow(radius: 20)
                .frame(maxWidth: 300)
            }
        }
        
        // MARK: - Main Site Menu Overlay - 🎯 주소창 위로 위치 조정 + 데스크탑 모드 확장
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
                    Color.black.opacity(0.1)
                        .ignoresSafeArea()
                        .onTapGesture {
                            manager.showSiteMenu = false
                        }

                    // 🎯 주소창 바로 위로 위치 변경
                    VStack(spacing: 0) {
                        Spacer()
                        
                        // 사이트 메뉴를 주소창 위에 표시
                        VStack(spacing: 0) {
                            siteMenuContent
                        }
                        .background(whiteGlassBackground)
                        .overlay(whiteGlassOverlay)
                        .padding(.horizontal, outerHorizontalPadding)
                        .padding(.bottom, 10) // 주소창과의 간격
                        
                        // 주소창 영역을 위한 공간 확보
                        if showAddressBar {
                            Spacer()
                                .frame(height: 160) // 주소창 + 방문기록 영역
                        } else {
                            Spacer()
                                .frame(height: 110) // 툴바 영역만
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: manager.showSiteMenu)
            }

            @ViewBuilder
            private var siteMenuContent: some View {
                VStack(spacing: 0) {
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
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            let securityInfo = SiteMenuSystem.Settings.getSiteSecurityInfo(for: currentState.currentURL)
                            
                            Image(systemName: securityInfo.icon)
                                .foregroundColor(securityInfo.color)

                            Text(securityInfo.text)
                                .font(.headline)
                                .foregroundColor(securityInfo.color)

                            if SiteMenuSystem.Settings.getPopupBlockedCount() > 0 {
                                Text("(\(SiteMenuSystem.Settings.getPopupBlockedCount())개 차단됨)")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }

                        if let url = currentState.currentURL {
                            Text(url.host ?? url.absoluteString)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()
                }
            }
            
            // ⚙️ 퀵 설정 섹션 - 데스크탑 모드 확장 (2배 너비) 및 위치 변경
            @ViewBuilder
            private var quickSettingsSection: some View {
                VStack(spacing: 8) {
                    // 첫 번째 줄: 팝업 차단 + 성능 (위치 바뀜)
                    HStack {
                        quickSettingButton(
                            icon: "shield.fill",
                            title: "팝업 차단",
                            isOn: manager.popupBlocked,
                            color: manager.popupBlocked ? .blue : .gray
                        ) {
                            manager.togglePopupBlocking()
                        }
                        
                        quickSettingButton(
                            icon: "speedometer",
                            title: "성능",
                            isOn: false,
                            color: .red
                        ) {
                            manager.showPerformanceSettings = true
                        }
                    }
                    
                    // 두 번째 줄: 데스크탑 모드 (2배 너비로 확장)
                    VStack(spacing: 8) {
                        // 데스크탑 모드 토글 버튼 (전체 너비)
                        Button(action: {
                            manager.toggleDesktopMode()
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: manager.getDesktopModeEnabled() ? "display" : "iphone")
                                    .font(.title2)
                                    .foregroundColor(manager.getDesktopModeEnabled() ? .blue : .gray)
                                
                                Text("데스크탑 모드")
                                    .font(.headline)
                                    .foregroundColor(manager.getDesktopModeEnabled() ? .primary : .secondary)
                                
                                Spacer()
                                
                                Text(manager.getDesktopModeEnabled() ? "ON" : "OFF")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(manager.getDesktopModeEnabled() ? Color.blue : Color.gray)
                                    .foregroundColor(.white)
                                    .cornerRadius(12)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(manager.getDesktopModeEnabled() ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(manager.getDesktopModeEnabled() ? Color.blue.opacity(0.3) : Color.gray.opacity(0.2), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        
                        // 데스크탑 모드가 켜져있을 때만 슬라이더와 배율 컨트롤 표시
                        if manager.getDesktopModeEnabled() {
                            desktopZoomControls
                        }
                    }
                }
            }
            
            @ViewBuilder
            private func quickSettingButton(icon: String, title: String, isOn: Bool, color: Color, action: @escaping () -> Void) -> some View {
                Button(action: action) {
                    VStack(spacing: 4) {
                        Image(systemName: icon)
                            .font(.title2)
                            .foregroundColor(color)
                        
                        Text(title)
                            .font(.caption)
                            .foregroundColor(isOn ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(isOn ? color.opacity(0.1) : Color.clear)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isOn ? color.opacity(0.3) : Color.gray.opacity(0.2), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            
            // 🖥️ 확장된 데스크탑 줌 컨트롤 (슬라이더 + 배율 프리셋)
            @ViewBuilder
            private var desktopZoomControls: some View {
                VStack(spacing: 12) {
                    // 현재 줌 레벨 표시
                    HStack {
                        Text("페이지 배율")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        
                        Spacer()
                        
                        Text("\(String(format: "%.0f", manager.getZoomLevel() * 100))%")
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundColor(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(8)
                    }
                    
                    // 슬라이더 컨트롤
                    VStack(spacing: 8) {
                        HStack(spacing: 12) {
                            Text("30%")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            
                            Slider(value: Binding(
                                get: { manager.getZoomLevel() },
                                set: { newValue in
                                    manager.setZoomLevel(newValue)
                                }
                            ), in: 0.3...3.0, step: 0.1)
                            .accentColor(.blue)
                            
                            Text("300%")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        // 빠른 배율 조정 버튼들
                        HStack(spacing: 8) {
                            Button("-") {
                                manager.adjustZoom(-0.1)
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                            .frame(width: 32, height: 32)
                            .background(Color.blue.opacity(0.1))
                            .foregroundColor(.blue)
                            .cornerRadius(8)
                            
                            Spacer()
                            
                            Button("리셋") {
                                manager.setZoomLevel(1.0)
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            }
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.gray.opacity(0.1))
                            .foregroundColor(.primary)
                            .cornerRadius(8)
                            
                            Spacer()
                            
                            Button("+") {
                                manager.adjustZoom(0.1)
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                            .frame(width: 32, height: 32)
                            .background(Color.blue.opacity(0.1))
                            .foregroundColor(.blue)
                            .cornerRadius(8)
                        }
                    }
                    
                    // 배율 프리셋 버튼들
                    VStack(spacing: 8) {
                        Text("빠른 배율 선택")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                            ForEach(SiteMenuSystem.Desktop.getZoomPresets(), id: \.self) { preset in
                                Button("\(String(format: "%.0f", preset * 100))%") {
                                    manager.setZoomLevel(preset)
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(abs(manager.getZoomLevel() - preset) < 0.05 ? Color.blue : Color.gray.opacity(0.2))
                                .foregroundColor(abs(manager.getZoomLevel() - preset) < 0.05 ? .white : .primary)
                                .cornerRadius(8)
                            }
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
                .background(Color.blue.opacity(0.05))
                .cornerRadius(12)
            }

            @ViewBuilder
            private var menuOptionsSection: some View {
                VStack(spacing: 12) {
                    HStack {
                        menuOptionRow(
                            icon: "line.3.horizontal.decrease.circle",
                            title: "방문 기록 관리",
                            subtitle: "\(manager.historyFilters.count)개 필터",
                            color: .orange
                        ) {
                            manager.showHistoryFilterManager = true
                        }
                        
                        Spacer()
                        
                        menuOptionRow(
                            icon: "shield.lefthalf.filled",
                            title: "개인정보",
                            subtitle: "쿠키 & 캐시",
                            color: .purple
                        ) {
                            manager.showPrivacySettings = true
                        }
                    }
                    
                    // 빈 공간으로 균형 맞춤
                    HStack {
                        Color.clear
                            .frame(maxWidth: .infinity)
                        
                        Spacer()
                        
                        Color.clear
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            
            @ViewBuilder
            private func menuOptionRow(icon: String, title: String, subtitle: String, color: Color, action: @escaping () -> Void) -> some View {
                Button(action: action) {
                    VStack(spacing: 4) {
                        Image(systemName: icon)
                            .font(.title2)
                            .foregroundColor(color)
                        
                        Text(title)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.gray.opacity(0.05))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            @ViewBuilder
            private var downloadsSection: some View {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button(action: {
                            manager.showDownloadsList = true
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundColor(.blue)
                                    .frame(width: 20)

                                Text("다운로드")
                                    .font(.headline)
                                    .foregroundColor(.primary)

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        if !manager.downloads.isEmpty {
                            Text("\(manager.downloads.count)개")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(12)
                        }
                    }

                    if !manager.downloads.isEmpty {
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(Array(manager.downloads.prefix(3))) { download in
                                    downloadRow(download)
                                }

                                if manager.downloads.count > 3 {
                                    HStack {
                                        Spacer()
                                        Text("및 \(manager.downloads.count - 3)개 더...")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                        .frame(maxHeight: 100)
                    } else {
                        HStack {
                            Spacer()
                            VStack(spacing: 4) {
                                Image(systemName: "tray")
                                    .font(.title3)
                                    .foregroundColor(.secondary.opacity(0.6))

                                Text("다운로드된 파일이 없습니다")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 16)
                    }
                }
            }

            @ViewBuilder
            private func downloadRow(_ download: DownloadItem) -> some View {
                HStack {
                    Image(systemName: "doc.fill")
                        .foregroundColor(.blue)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(download.filename)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(1)

                        HStack {
                            Text(download.size)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Spacer()

                            Text(RelativeDateTimeFormatter().localizedString(for: download.date, relativeTo: Date()))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(Color.white.opacity(0.95))
                .cornerRadius(8)
            }
        }
        
        // MARK: - Recent Visits View
        struct RecentVisitsView: View {
            @ObservedObject var manager: SiteMenuManager
            let onURLSelected: (URL) -> Void
            let onManageHistory: () -> Void

            var body: some View {
                VStack(spacing: 0) {
                    if manager.recentVisits.isEmpty {
                        emptyStateView
                    } else {
                        historyListView
                    }
                }
            }

            @ViewBuilder
            private var emptyStateView: some View {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title2)
                        .foregroundColor(.secondary)

                    Text("최근 방문한 사이트가 없습니다")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 20)
            }

            @ViewBuilder
            private var historyListView: some View {
                VStack(spacing: 0) {
                    ForEach(manager.recentVisits) { entry in
                        historyRow(entry)

                        if entry.id != manager.recentVisits.last?.id {
                            Divider()
                                .padding(.horizontal, 14)
                        }
                    }
                }
            }

            @ViewBuilder
            private func historyRow(_ entry: HistoryEntry) -> some View {
                Button(action: {
                    onURLSelected(entry.url)
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "clock")
                            .foregroundColor(.blue)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.primary)
                                .lineLimit(1)

                            Text(entry.url.absoluteString)
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Text(RelativeDateTimeFormatter().localizedString(for: entry.date, relativeTo: Date()))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        
        // MARK: - Autocomplete View
        struct AutocompleteView: View {
            @ObservedObject var manager: SiteMenuManager
            let searchText: String
            let onURLSelected: (URL) -> Void
            let onManageHistory: () -> Void

            var body: some View {
                VStack(spacing: 0) {
                    if manager.getAutocompleteEntries(for: searchText).isEmpty {
                        emptyStateView
                    } else {
                        autocompleteListView
                    }
                }
            }

            @ViewBuilder
            private var emptyStateView: some View {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundColor(.secondary)

                    Text("'\(searchText)'에 대한 방문 기록이 없습니다")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 20)
            }

            @ViewBuilder
            private var autocompleteListView: some View {
                VStack(spacing: 0) {
                    ForEach(manager.getAutocompleteEntries(for: searchText)) { entry in
                        autocompleteRow(entry)

                        if entry.id != manager.getAutocompleteEntries(for: searchText).last?.id {
                            Divider()
                                .padding(.horizontal, 14)
                        }
                    }
                }
            }

            @ViewBuilder
            private func autocompleteRow(_ entry: HistoryEntry) -> some View {
                Button(action: {
                    onURLSelected(entry.url)
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.gray)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            highlightedText(entry.title, searchText: searchText)
                                .font(.system(size: 16, weight: .medium))
                                .lineLimit(1)

                            highlightedText(entry.url.absoluteString, searchText: searchText)
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Image(systemName: "arrow.up.left")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            @ViewBuilder
            private func highlightedText(_ text: String, searchText: String) -> some View {
                let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

                if trimmed.isEmpty {
                    Text(text)
                        .foregroundColor(.primary)
                } else {
                    let parts = text.components(separatedBy: trimmed)

                    if parts.count > 1 {
                        HStack(spacing: 0) {
                            ForEach(0..<parts.count, id: \.self) { index in
                                Text(parts[index])
                                    .foregroundColor(.primary)

                                if index < parts.count - 1 {
                                    Text(trimmed)
                                        .foregroundColor(.blue)
                                        .fontWeight(.semibold)
                                }
                            }
                        }
                    } else {
                        Text(text)
                            .foregroundColor(.primary)
                    }
                }
            }
        }
        
        // MARK: - Downloads List View
        struct DownloadsListView: View {
            @ObservedObject var manager: SiteMenuManager
            @State private var searchText = ""
            @State private var showClearAllAlert = false
            @Environment(\.dismiss) private var dismiss

            private var filteredDownloads: [DownloadItem] {
                if searchText.isEmpty {
                    return manager.downloads
                } else {
                    return manager.downloads.filter {
                        $0.filename.localizedCaseInsensitiveContains(searchText)
                    }
                }
            }

            var body: some View {
                List {
                    if filteredDownloads.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)

                            Text(searchText.isEmpty ? "다운로드된 파일이 없습니다" : "검색 결과가 없습니다")
                                .font(.title3)
                                .foregroundColor(.secondary)

                            if searchText.isEmpty {
                                Text("웹에서 파일을 다운로드하면 여기에 표시됩니다\n(앱 내부 Documents/Downloads 폴더)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(filteredDownloads) { download in
                            DownloadListRow(download: download, manager: manager)
                        }
                        .onDelete(perform: deleteDownloads)
                    }
                }
                .navigationTitle("다운로드")
                .navigationBarTitleDisplayMode(.large)
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("닫기") {
                            dismiss()
                        }
                    }

                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            if !manager.downloads.isEmpty {
                                Button(role: .destructive) {
                                    showClearAllAlert = true
                                } label: {
                                    Label("모든 파일 실제 삭제", systemImage: "trash.fill")
                                }

                                Button {
                                    manager.clearDownloads()
                                } label: {
                                    Label("목록만 지우기", systemImage: "list.dash")
                                }
                            }

                            Button {
                                openDownloadsFolder()
                            } label: {
                                Label("파일 앱에서 열기", systemImage: "folder")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .alert("모든 다운로드 파일 삭제", isPresented: $showClearAllAlert) {
                    Button("취소", role: .cancel) { }
                    Button("실제 파일 삭제", role: .destructive) {
                        manager.clearAllDownloadFiles()
                    }
                } message: {
                    Text("다운로드 폴더의 모든 파일을 실제로 삭제하시겠습니까?\n이 작업은 되돌릴 수 없습니다.")
                }
            }

            private func deleteDownloads(at offsets: IndexSet) {
                for index in offsets {
                    let download = filteredDownloads[index]
                    manager.deleteDownloadFile(download)
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
        
        // MARK: - Download List Row
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
                HStack(spacing: 12) {
                    Image(systemName: fileIcon)
                        .font(.title2)
                        .foregroundColor(fileIconColor)
                        .frame(width: 40, height: 40)
                        .background(fileIconColor.opacity(0.1))
                        .cornerRadius(8)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(download.filename)
                            .font(.headline)
                            .lineLimit(2)

                        HStack {
                            Text(download.size)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Spacer()

                            Text(RelativeDateTimeFormatter().localizedString(for: download.date, relativeTo: Date()))
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if let fileURL = download.fileURL {
                                if FileManager.default.fileExists(atPath: fileURL.path) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                } else {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                    }

                    Spacer()

                    Menu {
                        if let fileURL = download.fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                            Button {
                                openFile(fileURL)
                            } label: {
                                Label("열기", systemImage: "doc.text")
                            }

                            Button {
                                shareFile(fileURL)
                            } label: {
                                Label("공유", systemImage: "square.and.arrow.up")
                            }

                            Divider()

                            Button(role: .destructive) {
                                manager.deleteDownloadFile(download)
                            } label: {
                                Label("실제 파일 삭제", systemImage: "trash.fill")
                            }
                        } else {
                            Text("파일이 존재하지 않음")
                                .foregroundColor(.secondary)
                        }

                        Button(role: .destructive) {
                            manager.removeDownload(download)
                        } label: {
                            Label("목록에서만 제거", systemImage: "list.dash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if let fileURL = download.fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                        openFile(fileURL)
                    }
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
        
        // MARK: - History Filter Manager View  
        struct HistoryFilterManagerView: View {
            @ObservedObject var manager: SiteMenuManager
            @Environment(\.dismiss) private var dismiss

            @State private var showAddFilterSheet = false
            @State private var newFilterType: HistoryFilter.FilterType = .keyword
            @State private var newFilterValue = ""
            @State private var showClearAllAlert = false
            @State private var editingFilter: HistoryFilter?
            @State private var editingValue = ""

            private var keywordFilters: [HistoryFilter] {
                manager.historyFilters.filter { $0.type == .keyword }
            }

            private var domainFilters: [HistoryFilter] {
                manager.historyFilters.filter { $0.type == .domain }
            }

            var body: some View {
                List {
                    Section {
                        Toggle("방문 기록 필터링", isOn: $manager.isHistoryFilteringEnabled)
                            .font(.headline)
                    } header: {
                        Text("필터 설정")
                    } footer: {
                        Text("필터링을 켜면 설정한 키워드나 도메인이 포함된 방문 기록이 주소창 자동완성에서 숨겨집니다.")
                    }

                    if manager.isHistoryFilteringEnabled && !manager.historyFilters.isEmpty {
                        Section("현재 필터 상태") {
                            let enabledCount = manager.historyFilters.filter { $0.isEnabled }.count
                            let totalCount = manager.historyFilters.count

                            HStack {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                    .foregroundColor(.blue)

                                Text("활성 필터: \(enabledCount) / \(totalCount)개")
                                    .font(.subheadline)

                                Spacer()

                                if enabledCount > 0 {
                                    Text("적용 중")
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.blue.opacity(0.1))
                                        .foregroundColor(.blue)
                                        .cornerRadius(8)
                                }
                            }
                        }
                    }

                    if !keywordFilters.isEmpty {
                        Section("키워드 필터") {
                            ForEach(keywordFilters) { filter in
                                filterRow(filter)
                            }
                            .onDelete { offsets in
                                for index in offsets {
                                    manager.removeHistoryFilter(keywordFilters[index])
                                }
                            }
                        }
                    }

                    if !domainFilters.isEmpty {
                        Section("도메인 필터") {
                            ForEach(domainFilters) { filter in
                                filterRow(filter)
                            }
                            .onDelete { offsets in
                                for index in offsets {
                                    manager.removeHistoryFilter(domainFilters[index])
                                }
                            }
                        }
                    }

                    if manager.historyFilters.isEmpty {
                        Section {
                            VStack(spacing: 16) {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                    .font(.system(size: 48))
                                    .foregroundColor(.secondary)

                                VStack(spacing: 8) {
                                    Text("설정된 필터가 없습니다")
                                        .font(.headline)
                                        .foregroundColor(.secondary)

                                    Text("키워드나 도메인 필터를 추가하여\n원하지 않는 방문 기록을 숨길 수 있습니다")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                .navigationTitle("방문 기록 관리")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("닫기") {
                            dismiss()
                        }
                    }

                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button {
                                showAddFilterSheet = true
                            } label: {
                                Label("필터 추가", systemImage: "plus")
                            }

                            if !manager.historyFilters.isEmpty {
                                Divider()

                                Button(role: .destructive) {
                                    showClearAllAlert = true
                                } label: {
                                    Label("모든 필터 삭제", systemImage: "trash")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .sheet(isPresented: $showAddFilterSheet) {
                    addFilterSheet
                }
                .alert("필터 수정", isPresented: Binding(
                    get: { editingFilter != nil },
                    set: { if !$0 { editingFilter = nil } }
                )) {
                    TextField("필터 값", text: $editingValue)
                    Button("취소", role: .cancel) {
                        editingFilter = nil
                        editingValue = ""
                    }
                    Button("저장") {
                        if let filter = editingFilter {
                            manager.updateHistoryFilter(filter, newValue: editingValue)
                        }
                        editingFilter = nil
                        editingValue = ""
                    }
                } message: {
                    if let filter = editingFilter {
                        Text("\(filter.type.displayName) 필터를 수정하세요")
                    }
                }
                .alert("모든 필터 삭제", isPresented: $showClearAllAlert) {
                    Button("취소", role: .cancel) { }
                    Button("삭제", role: .destructive) {
                        manager.clearAllHistoryFilters()
                    }
                } message: {
                    Text("모든 히스토리 필터를 삭제하시겠습니까?")
                }
            }

            @ViewBuilder
            private func filterRow(_ filter: HistoryFilter) -> some View {
                HStack {
                    Image(systemName: filter.type.icon)
                        .foregroundColor(filter.isEnabled ? .blue : .gray)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(filter.value)
                            .font(.headline)
                            .foregroundColor(filter.isEnabled ? .primary : .secondary)

                        HStack {
                            Text(filter.type.displayName)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if filter.isEnabled {
                                Text("• 활성")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            } else {
                                Text("• 비활성")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }

                            Spacer()

                            Text(RelativeDateTimeFormatter().localizedString(for: filter.createdAt, relativeTo: Date()))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    Menu {
                        Button {
                            editingFilter = filter
                            editingValue = filter.value
                        } label: {
                            Label("수정", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            manager.removeHistoryFilter(filter)
                        } label: {
                            Label("삭제", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundColor(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        manager.toggleHistoryFilter(filter)
                    }
                }
            }

            @ViewBuilder
            private var addFilterSheet: some View {
                NavigationView {
                    Form {
                        Section("필터 종류") {
                            Picker("필터 종류", selection: $newFilterType) {
                                ForEach(HistoryFilter.FilterType.allCases, id: \.self) { type in
                                    HStack {
                                        Image(systemName: type.icon)
                                        Text(type.displayName)
                                    }
                                    .tag(type)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        Section {
                            TextField(placeholderText, text: $newFilterValue)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        } header: {
                            Text("\(newFilterType.displayName) 입력")
                        } footer: {
                            Text(footerText)
                        }

                        if !newFilterValue.isEmpty {
                            Section("미리보기") {
                                HStack {
                                    Image(systemName: newFilterType.icon)
                                        .foregroundColor(.blue)

                                    Text(newFilterValue.lowercased())
                                        .font(.headline)

                                    Spacer()

                                    Text("필터됨")
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.red.opacity(0.1))
                                        .foregroundColor(.red)
                                        .cornerRadius(8)
                                }
                            }
                        }
                    }
                    .navigationTitle("필터 추가")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("취소") {
                                showAddFilterSheet = false
                                resetAddFilterForm()
                            }
                        }

                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("추가") {
                                manager.addHistoryFilter(type: newFilterType, value: newFilterValue)
                                showAddFilterSheet = false
                                resetAddFilterForm()
                            }
                            .disabled(newFilterValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }

            private var placeholderText: String {
                switch newFilterType {
                case .keyword:
                    return "예: 광고, 스팸, 성인"
                case .domain:
                    return "예: example.com, ads.google.com"
                }
            }

            private var footerText: String {
                switch newFilterType {
                case .keyword:
                    return "페이지 제목이나 URL에 이 키워드가 포함된 방문 기록이 숨겨집니다."
                case .domain:
                    return "이 도메인의 방문 기록이 숨겨집니다. 정확한 도메인명을 입력하세요."
                }
            }

            private func resetAddFilterForm() {
                newFilterType = .keyword
                newFilterValue = ""
            }
        }
        
        // MARK: - Privacy Settings View
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
                        HStack {
                            VStack(alignment: .leading) {
                                Text("모든 쿠키 삭제")
                                    .font(.headline)
                                Text("로그인 상태가 해제됩니다")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Button("삭제") {
                                showClearCookiesAlert = true
                            }
                            .foregroundColor(.red)
                        }
                        
                        HStack {
                            VStack(alignment: .leading) {
                                Text("캐시 삭제")
                                    .font(.headline)
                                Text("이미지 및 파일 캐시를 삭제합니다")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Button("삭제") {
                                showClearCacheAlert = true
                            }
                            .foregroundColor(.red)
                        }
                        
                        HStack {
                            VStack(alignment: .leading) {
                                Text("모든 웹사이트 데이터 삭제")
                                    .font(.headline)
                                Text("쿠키, 캐시, 로컬 저장소 등 모든 데이터")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Button("모두 삭제") {
                                showClearAllDataAlert = true
                            }
                            .foregroundColor(.red)
                            .fontWeight(.semibold)
                        }
                    }
                    
                    Section("팝업 차단") {
                        HStack {
                            Text("차단된 팝업 수")
                                .font(.headline)
                            
                            Spacer()
                            
                            Text("\(SiteMenuSystem.Settings.getPopupBlockedCount())개")
                                .foregroundColor(.secondary)
                            
                            Button("초기화") {
                                SiteMenuSystem.Settings.resetPopupBlockedCount()
                            }
                            .font(.caption)
                        }
                        
                        HStack {
                            VStack(alignment: .leading) {
                                Text("도메인별 설정 관리")
                                    .font(.headline)
                                Text("사이트별 팝업 차단/허용 설정")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            let allowedCount = PopupBlockManager.shared.getAllowedDomains().count
                            Text("\(allowedCount)개 허용")
                                .foregroundColor(.secondary)
                            
                            Button("관리") {
                                showPopupDomainManager = true
                            }
                            .foregroundColor(.blue)
                        }
                    }
                }
                .navigationTitle("개인정보 보호")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("닫기") {
                            dismiss()
                        }
                    }
                }
                .sheet(isPresented: $showPopupDomainManager) {
                    NavigationView {
                        PopupDomainManagerView()
                    }
                }
                .alert("쿠키 삭제", isPresented: $showClearCookiesAlert) {
                    Button("취소", role: .cancel) { }
                    Button("삭제", role: .destructive) {
                        SiteMenuSystem.Settings.clearAllCookies()
                    }
                } message: {
                    Text("모든 웹사이트의 쿠키를 삭제하시겠습니까? 모든 사이트에서 로그아웃됩니다.")
                }
                .alert("캐시 삭제", isPresented: $showClearCacheAlert) {
                    Button("취소", role: .cancel) { }
                    Button("삭제", role: .destructive) {
                        SiteMenuSystem.Settings.clearCache()
                    }
                } message: {
                    Text("모든 캐시를 삭제하시겠습니까? 페이지 로딩이 일시적으로 느려질 수 있습니다.")
                }
                .alert("모든 웹사이트 데이터 삭제", isPresented: $showClearAllDataAlert) {
                    Button("취소", role: .cancel) { }
                    Button("모두 삭제", role: .destructive) {
                        SiteMenuSystem.Settings.clearWebsiteData()
                    }
                } message: {
                    Text("쿠키, 캐시, 로컬 저장소 등 모든 웹사이트 데이터를 삭제하시겠습니까? 이 작업은 되돌릴 수 없습니다.")
                }
            }
        }
        
        // MARK: - 🚫 새로운 팝업 도메인 관리 뷰
        struct PopupDomainManagerView: View {
            @Environment(\.dismiss) private var dismiss
            @State private var allowedDomains: [String] = []
            @State private var recentBlockedPopups: [PopupBlockManager.BlockedPopup] = []
            @State private var showAddDomainAlert = false
            @State private var newDomainText = ""
            @State private var showClearAllAllowedAlert = false
            
            var body: some View {
                List {
                    // 허용된 도메인 섹션
                    Section {
                        if allowedDomains.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "shield.checkered")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                                
                                Text("허용된 사이트가 없습니다")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                Text("특정 사이트의 팝업을 허용하려면\n해당 사이트에서 팝업 차단 알림이 나타날 때\n'이 사이트 허용' 버튼을 누르세요")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        } else {
                            ForEach(allowedDomains, id: \.self) { domain in
                                HStack {
                                    Image(systemName: "checkmark.shield.fill")
                                        .foregroundColor(.green)
                                        .frame(width: 24)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(domain)
                                            .font(.headline)
                                        
                                        Text("팝업 허용됨")
                                            .font(.caption)
                                            .foregroundColor(.green)
                                    }
                                    
                                    Spacer()
                                    
                                    Button("차단") {
                                        PopupBlockManager.shared.removeAllowedDomain(domain)
                                        refreshData()
                                    }
                                    .font(.caption)
                                    .foregroundColor(.red)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.red.opacity(0.1))
                                    .cornerRadius(8)
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("팝업 허용 사이트 (\(allowedDomains.count)개)")
                            
                            Spacer()
                            
                            if !allowedDomains.isEmpty {
                                Button("수동 추가") {
                                    showAddDomainAlert = true
                                }
                                .font(.caption)
                                .foregroundColor(.blue)
                            }
                        }
                    }
                    
                    // 최근 차단된 팝업 섹션
                    Section {
                        if recentBlockedPopups.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "shield.fill")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                                
                                Text("차단된 팝업이 없습니다")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        } else {
                            ForEach(recentBlockedPopups.indices, id: \.self) { index in
                                let popup = recentBlockedPopups[index]
                                
                                HStack {
                                    Image(systemName: "shield.slash.fill")
                                        .foregroundColor(.red)
                                        .frame(width: 24)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(popup.domain)
                                            .font(.headline)
                                        
                                        if !popup.url.isEmpty {
                                            Text(popup.url)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                        }
                                        
                                        Text(RelativeDateTimeFormatter().localizedString(for: popup.date, relativeTo: Date()))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    Button("허용") {
                                        PopupBlockManager.shared.allowPopupsForDomain(popup.domain)
                                        refreshData()
                                    }
                                    .font(.caption)
                                    .foregroundColor(.green)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.green.opacity(0.1))
                                    .cornerRadius(8)
                                }
                            }
                        }
                    } header: {
                        Text("최근 차단된 팝업 (\(recentBlockedPopups.count)개)")
                    } footer: {
                        if !recentBlockedPopups.isEmpty {
                            Text("차단된 팝업의 사이트를 허용 목록에 추가할 수 있습니다")
                        }
                    }
                }
                .navigationTitle("팝업 차단 관리")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("닫기") {
                            dismiss()
                        }
                    }
                    
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button {
                                showAddDomainAlert = true
                            } label: {
                                Label("도메인 수동 추가", systemImage: "plus")
                            }
                            
                            if !allowedDomains.isEmpty {
                                Divider()
                                
                                Button(role: .destructive) {
                                    showClearAllAllowedAlert = true
                                } label: {
                                    Label("모든 허용 사이트 제거", systemImage: "trash")
                                }
                            }
                            
                            Button {
                                SiteMenuSystem.Settings.resetPopupBlockedCount()
                                refreshData()
                            } label: {
                                Label("차단 기록 초기화", systemImage: "arrow.counterclockwise")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .onAppear {
                    refreshData()
                }
                .alert("도메인 추가", isPresented: $showAddDomainAlert) {
                    TextField("도메인명 (예: example.com)", text: $newDomainText)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    
                    Button("취소", role: .cancel) {
                        newDomainText = ""
                    }
                    
                    Button("추가") {
                        let trimmedDomain = newDomainText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedDomain.isEmpty {
                            PopupBlockManager.shared.allowPopupsForDomain(trimmedDomain)
                            refreshData()
                        }
                        newDomainText = ""
                    }
                    .disabled(newDomainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } message: {
                    Text("팝업을 허용할 도메인을 입력하세요")
                }
                .alert("모든 허용 사이트 제거", isPresented: $showClearAllAllowedAlert) {
                    Button("취소", role: .cancel) { }
                    Button("제거", role: .destructive) {
                        for domain in allowedDomains {
                            PopupBlockManager.shared.removeAllowedDomain(domain)
                        }
                        refreshData()
                    }
                } message: {
                    Text("모든 허용 사이트를 제거하시겠습니까?")
                }
            }
            
            private func refreshData() {
                allowedDomains = PopupBlockManager.shared.getAllowedDomains()
                recentBlockedPopups = PopupBlockManager.shared.getRecentBlockedPopups(limit: 20)
            }
        }
        
        // MARK: - Performance Settings View
        struct PerformanceSettingsView: View {
            @ObservedObject var manager: SiteMenuManager
            @Environment(\.dismiss) private var dismiss
            
            var body: some View {
                List {
                    Section("메모리 관리") {
                        let memoryUsage = SiteMenuSystem.Performance.getMemoryUsage()
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("메모리 사용량")
                                    .font(.headline)
                                
                                Spacer()
                                
                                Text("\(String(format: "%.0f", memoryUsage.used)) MB")
                                    .foregroundColor(.secondary)
                            }
                            
                            ProgressView(value: memoryUsage.used / memoryUsage.total)
                                .progressViewStyle(LinearProgressViewStyle(tint: memoryUsage.used / memoryUsage.total > 0.8 ? .red : .blue))
                                .scaleEffect(x: 1, y: 0.5)
                        }
                        
                        HStack {
                            VStack(alignment: .leading) {
                                Text("웹뷰 풀 정리")
                                    .font(.headline)
                                Text("사용하지 않는 웹뷰를 정리합니다")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Button("정리") {
                                manager.clearWebViewPool()
                            }
                            .foregroundColor(.blue)
                        }
                    }
                    
                    Section("캐시 설정") {
                        Toggle("이미지 압축", isOn: $manager.imageCompressionEnabled)
                            .font(.headline)
                        
                        if manager.imageCompressionEnabled {
                            Text("이미지를 자동으로 압축하여 메모리 사용량을 줄입니다")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Section("고급 설정") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("메모리 정리 임계값")
                                    .font(.headline)
                                
                                Spacer()
                                
                                Text("\(Int(manager.memoryThreshold * 100))%")
                                    .foregroundColor(.secondary)
                            }
                            
                            Slider(value: $manager.memoryThreshold, in: 0.5...0.95, step: 0.05)
                                .accentColor(.blue)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("웹뷰 풀 크기")
                                    .font(.headline)
                                
                                Spacer()
                                
                                Text("\(manager.webViewPoolSize)개")
                                    .foregroundColor(.secondary)
                            }
                            
                            Slider(value: Binding(
                                get: { Double(manager.webViewPoolSize) },
                                set: { manager.webViewPoolSize = Int($0) }
                            ), in: 5...20, step: 1)
                            .accentColor(.blue)
                        }
                    }
                }
                .navigationTitle("성능")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("닫기") {
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 🔧 ContentView Extension (Complete Integration with Popup Alert)
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
            // 🚫 팝업 차단 알림 오버레이
            .overlay {
                if manager.showPopupBlockedAlert {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
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
            .sheet(
                isPresented: Binding(
                    get: { manager.showDownloadsList },
                    set: { manager.showDownloadsList = $0 }
                )
            ) {
                NavigationView {
                    SiteMenuSystem.UI.DownloadsListView(manager: manager)
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { manager.showHistoryFilterManager },
                    set: { manager.showHistoryFilterManager = $0 }
                )
            ) {
                NavigationView {
                    SiteMenuSystem.UI.HistoryFilterManagerView(manager: manager)
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { manager.showPrivacySettings },
                    set: { manager.showPrivacySettings = $0 }
                )
            ) {
                NavigationView {
                    SiteMenuSystem.UI.PrivacySettingsView(manager: manager)
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { manager.showPerformanceSettings },
                    set: { manager.showPerformanceSettings = $0 }
                )
            ) {
                NavigationView {
                    SiteMenuSystem.UI.PerformanceSettingsView(manager: manager)
                }
            }
    }
}