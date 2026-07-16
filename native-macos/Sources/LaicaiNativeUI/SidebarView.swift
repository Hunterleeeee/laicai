import LaicaiNativeDomain
import LaicaiNativeFoundation
import SwiftUI

// MARK: - Dual-Mode Sidebar: Thread Rail (compact) ↔ Full List (expanded)
// Compact: 60px — avatar circles with status dot
// Expanded: 280px — full thread list with metadata

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showingSettings: Bool
    @Binding var showingCommandPalette: Bool
    @Binding var showWorkbench: Bool
    @Binding var isVisible: Bool

    @State private var renamingThreadID: UUID?
    @State private var renameText = ""
    @State private var deletingThreadID: UUID?
    @State private var showingAddConnector = false
    @State private var showingNewProjectSheet = false
    @State private var deletingProjectID: UUID?
    @State private var collapsedProjects: Set<UUID> = []
    @State private var expandedProjects: Set<UUID> = []
    @State private var recentHistoryLimit = 8
    @State private var olderHistoryLimit = 16
    @State private var projectHistoryLimits: [UUID: Int] = [:]
    @ObservedObject private var projectManager = ProjectManager.shared
    private let compactRailHistoryLimit = 32

    var body: some View {
        VStack(spacing: 0) {
            if isVisible {
                sidebarHeader
                expandedList
            } else {
                compactRail
            }
            bottomBar
        }
        .alert(
            "删除对话",
            isPresented: Binding(
                get: { deletingThreadID != nil },
                set: {
                    if !$0 {
                        deletingThreadID = nil
                    }
                }
            )
        ) {
            Button("取消", role: .cancel) {
                deletingThreadID = nil
            }
            Button("删除", role: .destructive) {
                if let id = deletingThreadID { store.deleteThread(id: id) }
                deletingThreadID = nil
            }
        } message: {
            Text("确定要删除这条对话吗？")
        }
        .alert(
            "重命名",
            isPresented: Binding(
                get: { renamingThreadID != nil },
                set: { if !$0 { renamingThreadID = nil } }
            )
        ) {
            TextField("标题", text: $renameText)
            Button("取消", role: .cancel) { renamingThreadID = nil }
            Button("确定") {
                if let id = renamingThreadID, !renameText.isEmpty {
                    store.renameThread(id: id, title: renameText)
                }
                renamingThreadID = nil
            }
        }
        .sheet(isPresented: $showingAddConnector) {
            ConnectorEditSheet(mode: .add) { conn in
                store.addConnector(conn)
                store.checkAllConnectorsHealth()
                ToastCenter.shared.success("已添加 \(conn.name)")
            } onSaveAndTest: { conn in
                store.addConnector(conn)
                store.checkConnectorHealth(id: conn.id)
                ToastCenter.shared.show("正在测试 \(conn.name)")
            }
        }
    }

    // MARK: - Expanded Navigation Header

    private var sidebarHeader: some View {
        return VStack(alignment: .leading, spacing: AppSpace.medium) {
            HStack(alignment: .center, spacing: AppSpace.small) {
                BrandLogo(size: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text("来财")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TextGrade.primary)
                    Text(brandSubtitle)
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: AppSpace.extraSmall)

                IconButton(icon: "sidebar.left", tooltip: "收起侧栏") {
                    isVisible = false
                }
            }
            .padding(.top, AppSpace.extraSmall)

            VStack(spacing: AppSpace.extraSmall) {
                PrimaryNavButton(icon: "hammer", title: "新任务", isSelected: false) {
                    startNewTask()
                }

                PrimaryNavButton(icon: "plus.message", title: "新会话", isSelected: false) {
                    store.newThread()
                }

                PrimaryNavButton(icon: "magnifyingglass", title: "搜索", isSelected: false) {
                    showingCommandPalette = true
                }

                PrimaryNavButton(icon: "sparkles", title: "技能", isSelected: store.state.workbenchTab == .skills && showWorkbench) {
                    openWorkbench(.skills)
                }

                PrimaryNavButton(icon: "cpu", title: "模型连接", isSelected: store.state.workbenchTab == .context && showWorkbench) {
                    openWorkbench(.context)
                }

                PrimaryNavButton(icon: "alarm", title: "定时会话", isSelected: store.state.workbenchTab == .schedules && showWorkbench) {
                    openWorkbench(.schedules)
                }
            }

            searchBar
                .padding(.top, AppSpace.extraSmall)

            HStack(spacing: AppSpace.extraSmall) {
                Text("历史记录")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(TextGrade.ghost)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    showingNewProjectSheet = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(TextGrade.ghost)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("新建项目")
            }
            .padding(.top, AppSpace.extraSmall)
        }
        .padding(.horizontal, AppSpace.medium)
        .padding(.top, AppSpace.small)
        .padding(.bottom, AppSpace.extraSmall)
    }

    // MARK: - Compact Rail (60px mode)

    private var compactRail: some View {
        let items = Array(filteredThreadItems.prefix(compactRailHistoryLimit))
        return ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: AppSpace.extraSmall) {
                Button {
                    isVisible = true
                } label: {
                    BrandLogo(size: 28)
                }
                .buttonStyle(.plain)
                .padding(.vertical, AppSpace.small)
                .help("展开导航")

                CompactRailButton(icon: "hammer", tooltip: "新任务") {
                    startNewTask()
                }

                CompactRailButton(icon: "plus.message", tooltip: "新会话") {
                    store.newThread()
                }

                CompactRailButton(icon: "magnifyingglass", tooltip: "搜索") {
                    showingCommandPalette = true
                }

                CompactRailButton(icon: "sparkles", tooltip: "技能") {
                    openWorkbench(.skills)
                }

                CompactRailButton(icon: "cpu", tooltip: "模型连接") {
                    openWorkbench(.context)
                }

                CompactRailButton(icon: "alarm", tooltip: "定时会话") {
                    openWorkbench(.schedules)
                }

                ForEach(items) { item in
                    Button {
                        selectThread(item)
                    } label: {
                        CompactThreadDot(
                            item: item,
                            isSelected: isSelected(item)
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu { threadMenu(for: item) }
                }
            }
            .padding(.horizontal, AppSpace.small)
            .padding(.vertical, AppSpace.extraSmall)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Expanded List (project-grouped, Codex style)

    private var expandedList: some View {
        let sections = SidebarHistorySections(
            items: filteredThreadItems,
            olderHistoryLimit: olderHistoryLimit,
            recentHistoryLimit: recentHistoryLimit
        )

        return ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: AppSpace.extraSmall) {
                if sections.isEmpty {
                    VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
                        Text("暂无内容")
                            .font(AppFont.captionMedium)
                            .foregroundStyle(TextGrade.secondary)
                        Text("从上方新建任务或会话开始。")
                            .font(AppFont.tiny)
                            .foregroundStyle(TextGrade.ghost)
                    }
                    .padding(.horizontal, AppSpace.small)
                    .padding(.vertical, AppSpace.medium)
                }

                if !sections.recentItems.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        sidebarSectionHeader("最近")
                        ForEach(sections.visibleRecentItems) { item in
                            Button {
                                selectThread(item)
                            } label: {
                                ExpandedThreadRow(item: item, isSelected: isSelected(item))
                                    .equatable()
                            }
                            .buttonStyle(.plain)
                            .contextMenu { threadMenu(for: item) }
                        }
                        if sections.hiddenRecentCount > 0 {
                            Button {
                                recentHistoryLimit += 8
                            } label: {
                                HStack(spacing: AppSpace.extraSmall) {
                                    Image(systemName: "ellipsis.circle")
                                        .font(.system(size: 11, weight: .medium))
                                    Text("显示更多最近")
                                    Text("\(sections.hiddenRecentCount)")
                                        .foregroundStyle(TextGrade.ghost)
                                }
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(TextGrade.muted)
                                .padding(.horizontal, AppSpace.small)
                                .frame(height: 28)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !projectManager.projects.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            sidebarSectionHeader("项目")
                            Spacer()
                            Button {
                                showingNewProjectSheet = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(TextGrade.ghost)
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.plain)
                            .help("新建项目")
                        }
                        .padding(.top, AppSpace.extraSmall)

                        ForEach(projectManager.projects) { project in
                            projectGroupView(project, projectThreads: sections.projectThreadsByID[project.id] ?? [])
                        }
                    }
                }

                if sections.hasOlderItems {
                    VStack(alignment: .leading, spacing: 2) {
                        sidebarSectionHeader("更早")
                        ForEach(sections.visibleOlderOrphanItems) { item in
                            Button {
                                selectThread(item)
                            } label: {
                                ExpandedThreadRow(item: item, isSelected: isSelected(item))
                                    .equatable()
                            }
                            .buttonStyle(.plain)
                            .contextMenu { threadMenu(for: item) }
                        }
                        if sections.hiddenOlderCount > 0 {
                            Button {
                                olderHistoryLimit += 16
                            } label: {
                                HStack(spacing: AppSpace.extraSmall) {
                                    Image(systemName: "ellipsis.circle")
                                        .font(.system(size: 11, weight: .medium))
                                    Text("显示更多历史")
                                    Text("\(sections.hiddenOlderCount)")
                                        .foregroundStyle(TextGrade.ghost)
                                }
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(TextGrade.muted)
                                .padding(.horizontal, AppSpace.small)
                                .frame(height: 28)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, AppSpace.medium)
            .padding(.bottom, AppSpace.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingNewProjectSheet) {
            NewProjectSheet().environmentObject(store)
        }
        .alert(
            "删除项目",
            isPresented: Binding(
                get: { deletingProjectID != nil },
                set: { if !$0 { deletingProjectID = nil } }
            )
        ) {
            Button("取消", role: .cancel) { deletingProjectID = nil }
            Button("删除", role: .destructive) {
                if let id = deletingProjectID {
                    projectManager.deleteProject(id: id)
                }
                deletingProjectID = nil
            }
        } message: {
            Text("确定要删除这个项目吗？项目文件不会被删除。")
        }
    }

    // MARK: - Project Group (collapsible header + nested threads)

    @ViewBuilder
    private func projectGroupView(_ project: Project, projectThreads: [ThreadRecord]) -> some View {
        let isActive = project.id == selectedProjectIDForDisplay
        let isCollapsed = collapsedProjects.contains(project.id)
        let isShowingAll = expandedProjects.contains(project.id)
        let projectLimit = projectHistoryLimits[project.id, default: 8]
        let collapsedLimit = 2
        let visibleLimit = isShowingAll ? projectLimit : collapsedLimit
        let displayThreads = isCollapsed ? [] : Array(projectThreads.prefix(visibleLimit))
        let hiddenCount = max(0, projectThreads.count - displayThreads.count)
        let hasMore = hiddenCount > 0 && !isCollapsed

        // Project header — tap activates project + expands; tap again collapses
        Button {
            withAnimation(AppAnimation.quick) {
                if isActive {
                    // Already active: just toggle collapse
                    if isCollapsed {
                        collapsedProjects.remove(project.id)
                    } else {
                        collapsedProjects.insert(project.id)
                        expandedProjects.remove(project.id)
                    }
                } else {
                    // Activate this project + expand + switch workspace
                    projectManager.openProject(id: project.id)
                    store.switchWorkspace(to: project.rootPath)
                    collapsedProjects.remove(project.id)
                }
            }
        } label: {
            HStack(spacing: AppSpace.small) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(TextGrade.ghost)
                    .frame(width: 10)

                Image(systemName: isActive ? "folder.fill" : "folder")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isActive ? Brand.jade : TextGrade.muted)

                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name)
                        .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                        .foregroundStyle(isActive ? TextGrade.primary : TextGrade.secondary)
                        .lineLimit(1)
                    if isActive {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Brand.jade)
                                .frame(width: 5, height: 5)
                            Text("已打开")
                                .font(AppFont.tiny)
                                .foregroundStyle(TextGrade.muted)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 0)

                if !projectThreads.isEmpty {
                    Text("\(projectThreads.count)")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(isActive ? Brand.jade : TextGrade.ghost)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(isActive ? Brand.jade.opacity(0.12) : SurfaceGrade.sunken.opacity(0.62))
                        )
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, AppSpace.small)
            .threadRailItem(isSelected: isActive)
        }
        .buttonStyle(.plain)
        .contextMenu { projectContextMenu(for: project) }

        // Nested threads
        ForEach(displayThreads) { item in
            Button {
                selectThread(item)
            } label: {
                ExpandedThreadRow(item: item, isSelected: isSelected(item))
                    .equatable()
            }
            .buttonStyle(.plain)
            .contextMenu { threadMenu(for: item) }
            .padding(.leading, AppSpace.large)
        }

        // "展开显示" link
        if hasMore {
            Button {
                expandedProjects.insert(project.id)
                projectHistoryLimits[project.id, default: 8] += 8
            } label: {
                HStack(spacing: AppSpace.extraSmall) {
                    Text(isShowingAll ? "继续显示" : "展开显示")
                    Text("\(hiddenCount)")
                        .foregroundStyle(TextGrade.ghost)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Brand.primary)
            }
            .buttonStyle(.plain)
            .padding(.leading, AppSpace.extraLarge)
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func projectContextMenu(for project: Project) -> some View {
        Button {
            projectManager.openProject(id: project.id)
            store.switchWorkspace(to: project.rootPath)
        } label: {
            Label("打开项目", systemImage: "folder")
        }

        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: project.rootPath))
        } label: {
            Label("Finder 中打开", systemImage: "arrow.right.circle")
        }

        Divider()

        Button {
            store.newThreadInProject(project.id)
        } label: {
            Label("新建会话", systemImage: "bubble.left.and.bubble.right")
        }

        Button(role: .destructive) {
            deletingProjectID = project.id
        } label: {
            Label("删除项目", systemImage: "trash")
        }
    }

    private var searchBar: some View {
        HStack(spacing: AppSpace.extraSmall) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TextGrade.ghost)
            TextField(
                "搜索对话和任务",
                text: Binding(
                    get: { store.state.searchText },
                    set: { store.updateSearchText($0) }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(TextGrade.primary)
            if !store.state.searchText.isEmpty {
                Button {
                    store.updateSearchText("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(TextGrade.ghost)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, AppSpace.small)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(SurfaceGrade.sunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(SurfaceGrade.border.opacity(0.5), lineWidth: 0.5)
        )
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        Group {
            if isVisible {
                let connectorLabel = activeConnectorLabel
                HStack(spacing: AppSpace.small) {
                    Circle()
                        .fill(store.state.activeConnector?.health.color ?? TextGrade.ghost)
                        .frame(width: 6, height: 6)

                    Text(connectorLabel)
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, AppSpace.medium)
                .padding(.top, AppSpace.small)
                .padding(.bottom, AppSpace.small + 2)
            } else {
                Circle()
                    .fill(store.state.activeConnector?.health.color ?? TextGrade.ghost)
                    .frame(width: 7, height: 7)
                    .padding(.vertical, AppSpace.medium)
                    .help(activeConnectorLabel)
            }
        }
        .background(SurfaceGrade.panel.opacity(0.92))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(SurfaceGrade.hairline.opacity(0.72))
                .frame(height: 0.5)
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func threadMenu(for item: ThreadRecord) -> some View {
        let thread = store.state.threads.first { $0.id == item.id }
        let title = thread?.title ?? item.title
        let isPinned = thread?.isPinned ?? item.isPinned
        let isArchived = thread?.isArchived ?? item.isArchived
        let hasContent = thread?.steps.isEmpty == false || item.hasContent

        Button {
            store.pinThread(id: item.id)
        } label: {
            Label(isPinned ? "取消置顶" : "置顶", systemImage: isPinned ? "pin.slash" : "pin")
        }
        Button {
            renamingThreadID = item.id
            renameText = title
        } label: {
            Label("重命名", systemImage: "pencil")
        }
        Divider()
        if thread?.canContinue == true {
            Button {
                store.continueThread(id: item.id)
            } label: {
                Label("继续", systemImage: "arrow.turn.down.right")
            }
        }
        Button {
            store.cloneThread(id: item.id)
        } label: {
            Label("克隆", systemImage: "doc.on.doc")
        }
        Button {
            if let json = store.exportThread(id: item.id) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(json, forType: .string)
                ToastCenter.shared.success("已复制到剪贴板")
            }
        } label: {
            Label("导出", systemImage: "arrow.up.doc")
        }
        Divider()
        Button {
            store.clearThreadEvents(id: item.id)
        } label: {
            Label("清空", systemImage: "eraser")
        }.disabled(!hasContent)
        Button {
            store.archiveThread(id: item.id)
        } label: {
            Label(isArchived ? "取消归档" : "归档", systemImage: "archivebox")
        }
        Button {
            deletingThreadID = item.id
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    // MARK: - Data Helpers

    private var filteredThreadItems: [ThreadRecord] {
        let searchText =
            store.state.debouncedSearchText.isEmpty
            ? store.state.searchText
            : store.state.debouncedSearchText
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let records = query.isEmpty ? store.cachedThreadRecordSummaries : store.state.filteredThreadSummaries
        return records.filter { !$0.isArchived }
    }

    private var activeConnectorLabel: String {
        guard let connector = store.state.activeConnector else { return "未连接" }
        return connector.modelName.isEmpty ? connector.name : connector.modelName
    }

    private func sidebarSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(TextGrade.ghost)
            .textCase(.uppercase)
            .padding(.top, AppSpace.extraSmall)
            .padding(.leading, AppSpace.extraSmall)
    }

    private var selectedProjectIDForDisplay: UUID? {
        if let selectedID = store.state.selectedThreadID {
            return store.state.threads.first(where: { $0.id == selectedID })?.projectID
        }
        return projectManager.activeProjectID
    }

    private func selectThread(_ item: ThreadRecord) {
        store.selectThread(id: item.id)
    }

    private func isSelected(_ item: ThreadRecord) -> Bool {
        store.state.selectedThreadID == item.id
    }

    private func openWorkbench(_ tab: WorkbenchTab) {
        store.selectWorkbenchTab(tab)
        NotificationCenter.default.post(name: .laicaiOpenWorkbench, object: tab)
    }

    private func startNewTask() {
        if let projectID = projectManager.activeProjectID {
            store.newThreadInProject(projectID)
        } else {
            store.newThread()
        }
        store.updateDraft("请直接处理这个目标：")
    }

    private var brandSubtitle: String {
        if let project = projectManager.activeProject { return project.name }
        return store.state.activeConnector?.modelName.isEmpty == false
            ? (store.state.activeConnector?.modelName ?? "全局会话")
            : "全局会话"
    }
}

private struct SidebarHistorySections {
    let recentItems: [ThreadRecord]
    let visibleRecentItems: [ThreadRecord]
    let hiddenRecentCount: Int
    let visibleOlderOrphanItems: [ThreadRecord]
    let hiddenOlderCount: Int
    let projectThreadsByID: [UUID: [ThreadRecord]]
    let isEmpty: Bool

    var hasOlderItems: Bool {
        !visibleOlderOrphanItems.isEmpty || hiddenOlderCount > 0
    }

    init(items: [ThreadRecord], olderHistoryLimit: Int, recentHistoryLimit: Int = 8) {
        isEmpty = items.isEmpty
        var recent: [ThreadRecord] = []
        var olderOrphans: [ThreadRecord] = []
        var groupedProjects: [UUID: [ThreadRecord]] = [:]

        for item in items {
            if let projectID = item.projectID {
                groupedProjects[projectID, default: []].append(item)
            } else if recent.count < 8 {
                recent.append(item)
            } else {
                olderOrphans.append(item)
            }
        }

        recentItems = recent
        visibleRecentItems = Array(recent.prefix(recentHistoryLimit))
        hiddenRecentCount = max(0, recent.count - visibleRecentItems.count)
        visibleOlderOrphanItems = Array(olderOrphans.prefix(olderHistoryLimit))
        hiddenOlderCount = max(0, olderOrphans.count - visibleOlderOrphanItems.count)
        projectThreadsByID = groupedProjects
    }
}

private struct PrimaryNavButton: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpace.small) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? TextGrade.primary : TextGrade.secondary)
                    .frame(width: 18)

                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? TextGrade.primary : TextGrade.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppSpace.small)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(isSelected ? SurfaceGrade.selected : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Compact Thread Dot (Rail Mode)

private struct CompactThreadDot: View {
    let item: ThreadRecord
    let isSelected: Bool

    private var statusColor: Color { agentTint }

    private var initial: String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = title.first else { return "A" }
        return String(first)
    }

    private var agentTint: Color {
        switch item.resolvedAgentState {
        case .planning, .running: return Brand.primary
        case .waitingForApproval: return Semantic.warning
        case .blocked, .failed: return Semantic.error
        case .paused: return TextGrade.muted
        case .completed: return Semantic.success
        case .archived: return TextGrade.ghost
        case .idle: return TextGrade.muted
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Selection indicator — flat tick on the left edge
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isSelected ? Brand.primary : Color.clear)
                .frame(width: 2.5, height: isSelected ? 18 : 0)
                .padding(.trailing, 4)

            ZStack {
                // Avatar tile
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(isSelected ? SurfaceGrade.selected : SurfaceGrade.elevated)
                    .frame(width: 34, height: 34)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                            .strokeBorder(
                                isSelected ? Brand.primary.opacity(0.30) : SurfaceGrade.hairline,
                                lineWidth: 0.6
                            )
                    )

                // Initial letter
                Text(initial)
                    .font(AppFont.threadRail)
                    .foregroundStyle(isSelected ? Brand.primary : TextGrade.secondary)

                // Status dot (bottom-right) — only when there's something interesting
                if item.resolvedAgentState != .completed && item.resolvedAgentState != .idle {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().strokeBorder(SurfaceGrade.panel, lineWidth: 1.5))
                        .offset(x: 12, y: 12)
                }
            }
        }
        .frame(width: 46, height: 40)
        .contentShape(Rectangle())
        .help(item.title.isEmpty ? item.title : item.title)
    }
}

// MARK: - Sidebar Navigation Button

private struct SidebarNavButton: View {
    let icon: String
    let title: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpace.small) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? Brand.primary : TextGrade.muted)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.extraSmall, style: .continuous)
                            .fill(isSelected ? Brand.primary.opacity(0.12) : SurfaceGrade.elevated.opacity(0.45))
                    )

                Text(title)
                    .font(AppFont.captionMedium)
                    .foregroundStyle(isSelected ? TextGrade.primary : TextGrade.secondary)
                    .lineLimit(1)

                Spacer()

                Text(detail)
                    .font(AppFont.tiny)
                    .foregroundStyle(isSelected ? Brand.primary : TextGrade.ghost)
                    .lineLimit(1)
            }
            .padding(.horizontal, AppSpace.small)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(isSelected ? SurfaceGrade.selected : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Expanded Thread Row

private struct ExpandedThreadRow: View, Equatable {
    let item: ThreadRecord
    let isSelected: Bool

    static func == (lhs: ExpandedThreadRow, rhs: ExpandedThreadRow) -> Bool {
        lhs.isSelected == rhs.isSelected
            && lhs.item.id == rhs.item.id
            && lhs.item.title == rhs.item.title
            && lhs.item.status == rhs.item.status
            && lhs.item.updatedAt == rhs.item.updatedAt
            && lhs.item.hasContent == rhs.item.hasContent
            && lhs.item.projectID == rhs.item.projectID
            && lhs.item.resolvedAgentState == rhs.item.resolvedAgentState
    }

    private var isRunning: Bool {
        item.resolvedAgentState == .running || item.resolvedAgentState == .planning
    }

    var body: some View {
        HStack(spacing: AppSpace.small) {
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.extraSmall, style: .continuous)
                    .fill(statusTint.opacity(isSelected ? 0.18 : 0.10))
                    .frame(width: 24, height: 24)
                Image(systemName: agentIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusTint)
                if isRunning {
                    Circle()
                        .fill(statusTint)
                        .frame(width: 5, height: 5)
                        .offset(x: 9, y: 9)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(rowTitle)
                    .font(isSelected ? AppFont.bodyMedium : AppFont.body)
                    .foregroundStyle(isSelected ? TextGrade.primary : TextGrade.secondary)
                    .lineLimit(1)

                if isRunning {
                    Text(item.resolvedAgentState.title)
                        .font(.system(size: 10))
                        .foregroundStyle(Brand.primary)
                        .lineLimit(1)
                } else if shouldShowStateLine {
                    Text(item.resolvedAgentState.title)
                        .font(.system(size: 10))
                        .foregroundStyle(statusTint)
                }
            }

            Spacer(minLength: 0)

            Text(RelativeTimeFormatter.string(for: item.updatedAt))
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(TextGrade.ghost)
        }
        .padding(.horizontal, AppSpace.small)
        .padding(.vertical, AppSpace.extraSmall)
        .threadRailItem(isSelected: isSelected)
        .contentShape(Rectangle())
    }

    private var statusTint: Color {
        switch item.resolvedAgentState {
        case .planning, .running: return Brand.primary
        case .waitingForApproval: return Semantic.warning
        case .blocked, .failed: return Semantic.error
        case .paused: return Semantic.warning
        case .completed: return Semantic.success
        case .archived: return TextGrade.ghost
        case .idle: return TextGrade.muted
        }
    }

    private var agentIcon: String {
        switch item.resolvedAgentState {
        case .planning: return "list.bullet.clipboard"
        case .running: return "waveform.path.ecg"
        case .waitingForApproval: return "hand.raised.fill"
        case .blocked, .failed: return "exclamationmark.triangle.fill"
        case .paused: return "pause.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .archived: return "archivebox.fill"
        case .idle:
            if item.hasContent { return "bubble.left.and.bubble.right" }
            return "sparkles"
        }
    }

    private var rowTitle: String {
        let trimmed = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "新线程" || trimmed == "新对话" {
            return "新对话"
        }
        return TextHelper.compactTitle(trimmed)
    }

    private var shouldShowStateLine: Bool {
        switch item.resolvedAgentState {
        case .waitingForApproval, .blocked, .paused, .failed:
            return true
        case .idle, .planning, .running, .completed, .archived:
            return false
        }
    }
}

// MARK: - Compact Rail Button

private struct CompactRailButton: View {
    let icon: String
    var tooltip: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(TextGrade.muted)
                .frame(width: 34, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                        .fill(Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}

// MARK: - Icon Button

struct IconButton: View {
    let icon: String
    var tooltip: String = ""
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? TextGrade.primary : TextGrade.muted)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                        .fill(isHovered ? SurfaceGrade.hover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(tooltip)
    }
}
