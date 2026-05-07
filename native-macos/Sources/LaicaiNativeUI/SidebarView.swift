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
                    CompactThreadDot(
                        item: item,
                        isSelected: isSelected(item)
                    )
                    .onTapGesture { selectThread(item) }
                    .contextMenu { threadMenu(for: item) }
                }
            }
            .padding(.horizontal, AppSpace.sm)
            .padding(.vertical, AppSpace.xs)
        }
    }

    // MARK: - Expanded List (280px mode)

    private var expandedList: some View {
        List {
            ForEach(Array(timeGroupedThreads.enumerated()), id: \.element.0) { _, pair in
                let (group, items) = pair

                Section {
                    ForEach(items) { item in
                        ExpandedThreadRow(item: item, isSelected: isSelected(item))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 1, leading: AppSpace.xs, bottom: 1, trailing: AppSpace.xs))
                            .onTapGesture { selectThread(item) }
                            .contextMenu { threadMenu(for: item) }
                    }
                } header: {
                    Text(group)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(TextGrade.ghost)
                        .textCase(.uppercase)
                        .padding(.top, 4)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        Group {
            if isVisible {
                // Expanded: new thread + settings
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

    private var timeGroupedThreads: [(String, [ThreadRecord])] {
        let items = filteredThreadItems
        let cal = Calendar.current
        let now = Date()
        let today = items.filter { cal.isDateInToday($0.updatedAt) }
        let yesterday = items.filter { cal.isDate($0.updatedAt, equalTo: now.addingTimeInterval(-86400), toGranularity: .day) }
        let earlier = items.filter { !cal.isDateInToday($0.updatedAt) && !cal.isDate($0.updatedAt, equalTo: now.addingTimeInterval(-86400), toGranularity: .day) }
        var groups: [(String, [ThreadRecord])] = []
        if !today.isEmpty { groups.append(("今天", today)) }
        if !yesterday.isEmpty { groups.append(("昨天", yesterday)) }
        if !earlier.isEmpty { groups.append(("更早", earlier)) }
        return groups
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
                Text(item.shortID)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(TextGrade.ghost)
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
        .onAppear { if isRunning { dotPhase = true } }
        .onChange(of: isRunning) { running in
            dotPhase = running
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
