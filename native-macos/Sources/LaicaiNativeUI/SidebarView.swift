import SwiftUI
import LaicaiNativeDomain
import LaicaiNativeFoundation

// MARK: - Dual-Mode Sidebar: Thread Rail (compact) ↔ Full List (expanded)
// Compact: 60px — avatar circles with status dot
// Expanded: 280px — full thread list with metadata

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showingSettings: Bool
    @Binding var isVisible: Bool

    @State private var renamingSessionID: UUID?
    @State private var renameText = ""
    @State private var deletingSessionID: UUID?
    @State private var deletingTaskID: UUID?
    @State private var showingAddConnector = false
    @State private var showingNewProjectSheet = false
    @State private var deletingProjectID: UUID?
    @State private var collapsedProjects: Set<UUID> = []
    @State private var isHoveringProject: UUID?
    @ObservedObject private var projectManager = ProjectManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // Logo/brand at top
            brandMark

            // Thread list — compact or expanded
            if isVisible {
                expandedList
            } else {
                compactRail
            }

            // Bottom actions
            bottomBar
        }
        .alert("删除会话", isPresented: Binding(
            get: { deletingSessionID != nil || deletingTaskID != nil },
            set: {
                if !$0 {
                    deletingSessionID = nil
                    deletingTaskID = nil
                }
            }
        )) {
            Button("取消", role: .cancel) {
                deletingSessionID = nil
                deletingTaskID = nil
            }
            Button("删除", role: .destructive) {
                if let id = deletingSessionID { store.deleteSession(id: id) }
                if let id = deletingTaskID { store.deleteTask(id: id) }
                deletingSessionID = nil
                deletingTaskID = nil
            }
        } message: { Text("确定要删除这个会话吗？") }
        .alert("重命名", isPresented: Binding(
            get: { renamingSessionID != nil },
            set: { if !$0 { renamingSessionID = nil } }
        )) {
            TextField("标题", text: $renameText)
            Button("取消", role: .cancel) { renamingSessionID = nil }
            Button("确定") {
                if let id = renamingSessionID, !renameText.isEmpty {
                    store.renameSession(id: id, title: renameText)
                }
                renamingSessionID = nil
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

    // MARK: - Brand Mark

    private var brandMark: some View {
        Group {
            if isVisible {
                // Expanded: logo + name + collapse button
                HStack(spacing: AppSpace.sm) {
                    brandCircle
                    Text("来财")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(TextGrade.primary)
                    Spacer()
                    IconButton(icon: "sidebar.left", tooltip: "收起") {
                        isVisible = false
                    }
                }
                .padding(.horizontal, AppSpace.md)
                .padding(.vertical, AppSpace.md)
            } else {
                // Compact: just logo circle, tap to expand
                Button {
                    isVisible = true
                } label: {
                    brandCircle
                }
                .buttonStyle(.plain)
                .padding(.vertical, AppSpace.md)
                .help("展开侧栏")
            }
        }
    }

    @State private var brandRingAngle: Double = 0

    private var brandCircle: some View {
        BrandLogo(size: 30)
            .shadow(color: Brand.primary.opacity(0.4), radius: 8, y: 0)
    }

    // MARK: - Compact Rail (60px mode)

    private var compactRail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: AppSpace.xs) {
                ForEach(filteredThreadItems) { item in
                    Button { selectThread(item) } label: {
                        CompactThreadDot(
                            item: item,
                            isSelected: isSelected(item)
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu { threadMenu(for: item) }
                }
            }
            .padding(.horizontal, AppSpace.sm)
            .padding(.vertical, AppSpace.xs)
        }
    }

    // MARK: - Expanded List (project-grouped, Codex style)

    private var expandedList: some View {
        List {
            // Section: 项目 (projects with nested threads)
            if !projectManager.projects.isEmpty {
                Section {
                    ForEach(projectManager.projects) { project in
                        projectGroupView(project)
                    }
                } header: {
                    HStack {
                        Text("项目")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(TextGrade.ghost)
                            .textCase(.uppercase)
                        Spacer()
                        Button {
                            showingNewProjectSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(TextGrade.ghost)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                }
            }

            // Section: 其他对话 (threads not belonging to any project)
            let orphanThreads = filteredThreadItems.filter { $0.projectID == nil }
            if !orphanThreads.isEmpty {
                Section {
                    ForEach(orphanThreads) { item in
                        Button { selectThread(item) } label: {
                            ExpandedThreadRow(item: item, isSelected: isSelected(item))
                        }
                        .buttonStyle(.plain)
                        .contextMenu { threadMenu(for: item) }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 1, leading: AppSpace.xs, bottom: 1, trailing: AppSpace.xs))
                    }
                } header: {
                    Text("其他对话")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(TextGrade.ghost)
                        .textCase(.uppercase)
                        .padding(.top, 4)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showingNewProjectSheet) {
            NewProjectSheet()
        }
        .alert("删除项目", isPresented: Binding(
            get: { deletingProjectID != nil },
            set: { if !$0 { deletingProjectID = nil } }
        )) {
            Button("取消", role: .cancel) { deletingProjectID = nil }
            Button("删除", role: .destructive) {
                if let id = deletingProjectID {
                    projectManager.deleteProject(id: id)
                }
                deletingProjectID = nil
            }
        } message: { Text("确定要删除这个项目吗？项目文件不会被删除。") }
    }

    // MARK: - Project Group (collapsible header + nested threads)

    @ViewBuilder
    private func projectGroupView(_ project: Project) -> some View {
        let isActive = project.id == projectManager.activeProjectID
        let isCollapsed = collapsedProjects.contains(project.id)
        let projectThreads = filteredThreadItems.filter { $0.projectID == project.id }
            .sorted { $0.updatedAt > $1.updatedAt }
        let displayThreads = isCollapsed ? [] : Array(projectThreads.prefix(5))
        let hasMore = projectThreads.count > 5 && !isCollapsed

        // Project header — tap activates project + expands; tap again collapses
        Button {
            withAnimation(AppAnimation.quick) {
                if isActive {
                    // Already active: just toggle collapse
                    if isCollapsed {
                        collapsedProjects.remove(project.id)
                    } else {
                        collapsedProjects.insert(project.id)
                    }
                } else {
                    // Activate this project + expand + switch workspace
                    projectManager.openProject(id: project.id)
                    store.switchWorkspace(to: project.rootPath)
                    collapsedProjects.remove(project.id)
                }
            }
        } label: {
            HStack(spacing: AppSpace.sm) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(TextGrade.ghost)
                    .frame(width: 10)

                Image(systemName: isActive ? "folder.fill" : "folder")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isActive ? Brand.primary : TextGrade.muted)

                Text(project.name)
                    .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? TextGrade.primary : TextGrade.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if !projectThreads.isEmpty {
                    Text("\(projectThreads.count)")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(TextGrade.ghost)
                }
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            Button {
                projectManager.openProject(id: project.id)
                store.switchWorkspace(to: project.rootPath)
                collapsedProjects.remove(project.id)
                store.newSessionInProject(project.id)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(TextGrade.muted)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHoveringProject == project.id ? 1 : 0)
            .offset(x: -2)
        }
        .onHover { hovering in
            isHoveringProject = hovering ? project.id : nil
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: AppSpace.xs, bottom: 0, trailing: AppSpace.xs))
        .contextMenu { projectContextMenu(for: project) }

        // Nested threads
        ForEach(displayThreads) { item in
            Button { selectThread(item) } label: {
                ExpandedThreadRow(item: item, isSelected: isSelected(item))
            }
            .buttonStyle(.plain)
            .contextMenu { threadMenu(for: item) }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 1, leading: AppSpace.xl, bottom: 1, trailing: AppSpace.xs))
        }

        // "展开显示" link
        if hasMore {
            Button {
                // Show all by removing from collapsed (it's already expanded, this means show all)
                // For simplicity, just remove collapse
                collapsedProjects.remove(project.id)
            } label: {
                Text("展开显示")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Brand.primary)
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: AppSpace.xl, bottom: 2, trailing: AppSpace.xs))
        }
    }

    @ViewBuilder
    private func projectContextMenu(for project: Project) -> some View {
        Button {
            projectManager.openProject(id: project.id)
            store.switchWorkspace(to: project.rootPath)
        } label: { Label("打开项目", systemImage: "folder") }

        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: project.rootPath))
        } label: { Label("Finder 中打开", systemImage: "arrow.right.circle") }

        Divider()

        Button(role: .destructive) {
            deletingProjectID = project.id
        } label: { Label("删除项目", systemImage: "trash") }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        Group {
            if isVisible {
                // Expanded: new session + new project + settings
                HStack(spacing: AppSpace.sm) {
                    Button {
                        store.newSession()
                    } label: {
                        HStack(spacing: AppSpace.xs) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                            Text("新会话")
                                .font(AppFont.captionMedium)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppSpace.sm)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                                .fill(Brand.premiumGradient)
                        )
                        .shadow(color: Brand.primary.opacity(0.3), radius: 8, y: 2)
                    }
                    .buttonStyle(.plain)

                    IconButton(icon: "folder.badge.plus", tooltip: "新项目") {
                        showingNewProjectSheet = true
                    }
                    IconButton(icon: "gearshape", tooltip: "设置") {
                        showingSettings = true
                    }
                }
                .padding(.horizontal, AppSpace.md)
                .padding(.vertical, AppSpace.sm)
            } else {
                // Compact: icon buttons stacked
                VStack(spacing: AppSpace.sm) {
                    CompactRailButton(icon: "plus", tooltip: "新会话") {
                        store.newSession()
                    }
                    CompactRailButton(icon: "folder.badge.plus", tooltip: "新项目") {
                        showingNewProjectSheet = true
                    }
                    CompactRailButton(icon: "gearshape", tooltip: "设置") {
                        showingSettings = true
                    }
                }
                .padding(.vertical, AppSpace.sm)
            }
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(SurfaceGrade.divider)
                .frame(height: 0.5)
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func threadMenu(for item: ThreadRecord) -> some View {
        switch item.source {
        case .session:
            if let session = item.session {
                Button { store.pinSession(id: session.id) } label: {
                    Label(session.isPinned ? "取消置顶" : "置顶", systemImage: session.isPinned ? "pin.slash" : "pin")
                }
                Button { renamingSessionID = session.id; renameText = session.title } label: {
                    Label("重命名", systemImage: "pencil")
                }
                Divider()
                Button { store.cloneSession(id: session.id) } label: {
                    Label("克隆", systemImage: "doc.on.doc")
                }
                Button {
                    if let json = store.exportSession(id: session.id) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(json, forType: .string)
                        ToastCenter.shared.success("已复制到剪贴板")
                    }
                } label: { Label("导出", systemImage: "arrow.up.doc") }
                Divider()
                Button { store.clearSessionTurns(id: session.id) } label: { Label("清空", systemImage: "eraser") }.disabled(session.turns.isEmpty)
                Button { store.archiveThread(id: session.id) } label: { Label(item.isArchived ? "取消归档" : "归档", systemImage: "archivebox") }
                Button(role: .destructive) { deletingSessionID = session.id } label: { Label("删除", systemImage: "trash") }
            }
        case .task:
            if let task = item.task {
                Button { store.prepareTaskContinuation(id: task.id) } label: { Label("继续处理", systemImage: "arrow.turn.down.right") }
                Divider()
                Button {
                    if let json = store.exportTask(id: task.id) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(json, forType: .string)
                        ToastCenter.shared.success("已复制到剪贴板")
                    }
                } label: { Label("导出", systemImage: "arrow.up.doc") }
                Divider()
                Button { store.archiveThread(id: task.id) } label: { Label(item.isArchived ? "取消归档" : "归档", systemImage: "archivebox") }
                Button(role: .destructive) { deletingTaskID = task.id } label: { Label("删除", systemImage: "trash") }
            }
        }
    }

    // MARK: - Data Helpers

    private var filteredThreadItems: [ThreadRecord] {
        store.state.filteredThreadSummaries.filter { !$0.isArchived }
    }

    private func selectThread(_ item: ThreadRecord) {
        switch item.source {
        case .session: store.selectSession(id: item.id)
        case .task: store.selectTask(id: item.id)
        }
    }

    private func isSelected(_ item: ThreadRecord) -> Bool {
        store.state.selectedThreadID == item.id && store.state.selectedThreadSource == item.source
    }
}

// MARK: - Compact Thread Dot (Rail Mode)

private struct CompactThreadDot: View {
    let item: ThreadRecord
    let isSelected: Bool
    @State private var isHovering = false

    private var statusColor: Color {
        if let s = item.status { return s.color }
        return TextGrade.ghost
    }

    private var initial: String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = title.first else { return "?" }
        return String(first)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Selection indicator — glowing bar
            RoundedRectangle(cornerRadius: 2)
                .fill(isSelected ? Brand.premiumGradient : LinearGradient(colors: [Color.clear], startPoint: .top, endPoint: .bottom))
                .frame(width: 3, height: isSelected ? 20 : 0)
                .shadow(color: isSelected ? Brand.primary.opacity(0.5) : .clear, radius: 4)
                .padding(.trailing, 4)

            ZStack {
                // Avatar circle
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .fill(isSelected ? Brand.primary.opacity(0.12) : (isHovering ? Color.white.opacity(0.06) : SurfaceGrade.card.opacity(0.5)))
                    .frame(width: 40, height: 40)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                            .strokeBorder(
                                isSelected ? Brand.primary.opacity(0.35) : Color.white.opacity(0.06),
                                lineWidth: isSelected ? 1 : 0.5
                            )
                    )

                // Initial letter
                Text(initial)
                    .font(AppFont.threadRail)
                    .foregroundStyle(isSelected ? Brand.primaryLight : TextGrade.secondary)

                // Status dot (bottom-right)
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusColor.opacity(0.5), radius: 2)
                    .overlay(Circle().strokeBorder(SurfaceGrade.panel, lineWidth: 1.5))
                    .offset(x: 14, y: 14)
            }
        }
        .frame(width: 52, height: 44)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(AppAnimation.micro) { isHovering = h } }
        .help(item.title)
    }
}

// MARK: - Expanded Thread Row

private struct ExpandedThreadRow: View {
    @EnvironmentObject private var store: AppStore
    let item: ThreadRecord
    let isSelected: Bool
    @State private var isHovering = false
    @State private var dotPhase: Bool = false
    @State private var cachedTokenLabel: String?
    @State private var didLoadTokens = false

    private var isRunning: Bool { item.status == .running }

    private var liveActivity: String {
        guard isRunning, isSelected else { return "" }
        return store.state.liveActivity
    }

    var body: some View {
        HStack(spacing: AppSpace.sm) {
            // Status indicator — pulse when running
            Circle()
                .fill(item.status?.color ?? TextGrade.ghost)
                .frame(width: 6, height: 6)
                .scaleEffect(isRunning && dotPhase ? 1.3 : 1.0)
                .opacity(isRunning && dotPhase ? 0.6 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: dotPhase)

            VStack(alignment: .leading, spacing: 2) {
                Text(TextHelper.compactTitle(item.title))
                    .font(isSelected ? AppFont.bodyMedium : AppFont.body)
                    .foregroundStyle(isSelected ? TextGrade.primary : TextGrade.secondary)
                    .lineLimit(1)

                if isRunning {
                    Text(!liveActivity.isEmpty ? liveActivity : "进行中")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Brand.primary)
                        .lineLimit(1)
                } else if item.status == .cancelled {
                    Text("已暂停")
                        .font(AppFont.tiny)
                        .foregroundStyle(Semantic.warning)
                } else if item.status == .failed {
                    Text("执行失败")
                        .font(AppFont.tiny)
                        .foregroundStyle(Semantic.error)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 1) {
                if let label = cachedTokenLabel {
                    Text(label)
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(TextGrade.ghost)
                } else {
                    Text(item.shortID)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(TextGrade.ghost)
                }
                Text(RelativeTimeFormatter.string(for: item.updatedAt))
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
            }
        }
        .padding(.horizontal, AppSpace.sm)
        .padding(.vertical, AppSpace.sm)
        .threadRailItem(isSelected: isSelected, isHovering: isHovering)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(AppAnimation.micro) { isHovering = h } }
        .onAppear {
            if isRunning { dotPhase = true }
            loadTokenLabel()
        }
        .onChange(of: isRunning) { running in
            dotPhase = running
        }
        .onChange(of: item.updatedAt) { _ in
            loadTokenLabel()
        }
    }

    private func loadTokenLabel() {
        let threadID = item.id.uuidString
        DispatchQueue.global(qos: .utility).async {
            let usage = UsageTracker.shared.threadUsage(threadID: threadID)
            let total = usage.inputTokens + usage.outputTokens
            let label: String? = {
                guard total > 0 else { return nil }
                if total >= 1_000_000 { return String(format: "%.1fM", Double(total) / 1_000_000) }
                if total >= 1_000 { return "\(total / 1000)k" }
                return "\(total)"
            }()
            DispatchQueue.main.async {
                cachedTokenLabel = label
                didLoadTokens = true
            }
        }
    }
}

// MARK: - Compact Rail Button

private struct CompactRailButton: View {
    let icon: String
    var tooltip: String = ""
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovering ? TextGrade.primary : TextGrade.muted)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                        .fill(isHovering ? SurfaceGrade.hover : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(AppAnimation.micro) { isHovering = h } }
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
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                        .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                        .strokeBorder(isHovered ? Color.white.opacity(0.10) : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(AppAnimation.quick) { isHovered = h } }
        .help(tooltip)
    }
}

// MARK: - New Project Sheet

struct NewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var projectName = ""
    @State private var selectedPath = ""
    @State private var createNew = false
    @State private var newFolderName = ""

    var body: some View {
        VStack(spacing: AppSpace.lg) {
            // Header
            HStack {
                Text("新建项目")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(TextGrade.primary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(TextGrade.ghost)
                }
                .buttonStyle(.plain)
            }

            // Project name
            VStack(alignment: .leading, spacing: 4) {
                Text("项目名称")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TextGrade.muted)
                TextField("例如：来财 macOS", text: $projectName)
                    .textFieldStyle(.roundedBorder)
            }

            // Mode toggle
            Picker("", selection: $createNew) {
                Text("选择已有文件夹").tag(false)
                Text("创建新文件夹").tag(true)
            }
            .pickerStyle(.segmented)

            if createNew {
                // Create new folder
                VStack(alignment: .leading, spacing: 4) {
                    Text("文件夹名称")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TextGrade.muted)
                    TextField("例如：my-project", text: $newFolderName)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Text("将创建在：")
                            .font(.system(size: 10))
                            .foregroundStyle(TextGrade.ghost)
                        Text(targetNewPath)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(TextGrade.muted)
                            .lineLimit(1)
                    }

                    Button("选择父目录...") {
                        pickFolder { path in selectedPath = path }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Brand.primary)
                }
            } else {
                // Select existing
                VStack(alignment: .leading, spacing: 4) {
                    Text("项目文件夹")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TextGrade.muted)

                    HStack {
                        Text(selectedPath.isEmpty ? "未选择" : abbreviateHome(selectedPath))
                            .font(.system(size: 11))
                            .foregroundStyle(selectedPath.isEmpty ? TextGrade.ghost : TextGrade.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button("选择文件夹...") {
                            pickFolder { path in
                                selectedPath = path
                                if projectName.isEmpty {
                                    projectName = URL(fileURLWithPath: path).lastPathComponent
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Brand.primary)
                    }
                    .padding(AppSpace.sm)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(SurfaceGrade.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(SurfaceGrade.border.opacity(0.3), lineWidth: 0.5)
                    )
                }
            }

            Spacer()

            // Actions
            HStack {
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(TextGrade.muted)

                Spacer()

                Button {
                    createProject()
                    dismiss()
                } label: {
                    Text("创建项目")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, AppSpace.lg)
                        .padding(.vertical, AppSpace.sm)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                                .fill(canCreate ? Brand.premiumGradient : LinearGradient(colors: [TextGrade.ghost], startPoint: .leading, endPoint: .trailing))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canCreate)
            }
        }
        .padding(AppSpace.xl)
        .frame(width: 420, height: 380)
        .background(SurfaceGrade.panel)
    }

    private var canCreate: Bool {
        if createNew {
            return !projectName.isEmpty && !newFolderName.isEmpty && !selectedPath.isEmpty
        } else {
            return !projectName.isEmpty && !selectedPath.isEmpty
        }
    }

    private var targetNewPath: String {
        guard !selectedPath.isEmpty, !newFolderName.isEmpty else { return "..." }
        return (selectedPath as NSString).appendingPathComponent(newFolderName)
    }

    @MainActor
    private func createProject() {
        let rootPath: String
        if createNew {
            rootPath = targetNewPath
            try? FileManager.default.createDirectory(atPath: rootPath, withIntermediateDirectories: true)
        } else {
            rootPath = selectedPath
        }
        guard !rootPath.isEmpty else { return }
        let _ = ProjectManager.shared.createProject(name: projectName, rootPath: rootPath)
    }

    private func pickFolder(completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            completion(url.path)
        }
    }

    private func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - TaskStatus Color Extension

extension TaskStatus {
    var color: Color {
        switch self {
        case .queued: return Semantic.warning
        case .running: return Brand.primary
        case .waitingReview: return Semantic.warning
        case .completed: return Semantic.success
        case .failed: return Semantic.error
        case .cancelled: return TextGrade.muted
        }
    }

    var label: String { title }
}

// MARK: - ConnectorHealth Color Extension

extension ConnectorHealth {
    var color: Color {
        switch self {
        case .ready: return Semantic.success
        case .attention: return Semantic.warning
        case .offline: return Semantic.error
        }
    }
}
