import LaicaiNativeDomain
import LaicaiNativeFoundation
import SwiftUI

public struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingSettings = false
    @State private var showSidebar = true
    @State private var showWorkbench = false
    @State private var showingCommandPalette = false
    @State private var sidebarExpanded = true
    @ObservedObject private var projectManager = ProjectManager.shared

    public init() {}

    public var body: some View {
        ZStack {
            workspaceBackground.ignoresSafeArea()

            HStack(spacing: 0) {
                SidebarView(
                    showingSettings: $showingSettings,
                    showingCommandPalette: $showingCommandPalette,
                    showWorkbench: $showWorkbench,
                    isVisible: $showSidebar
                )
                .frame(width: sidebarExpanded ? LayoutConst.threadRailExpandedWidth : LayoutConst.threadRailWidth)
                .background(SurfaceGrade.panel)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(SurfaceGrade.divider.opacity(0.72))
                        .frame(width: 0.5)
                }

                ZStack(alignment: .trailing) {
                    VStack(spacing: 0) {
                        AppTopBar(
                            showingSettings: $showingSettings,
                            showSidebar: $showSidebar,
                            showWorkbench: $showWorkbench,
                            showingCommandPalette: $showingCommandPalette
                        )
                        .environmentObject(store)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(SurfaceGrade.divider.opacity(0.50))
                                .frame(height: 0.5)
                        }

                        ChatDetailView(
                            showingSettings: $showingSettings
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(SurfaceGrade.base)
                    }

                    if showWorkbench {
                        workbenchDrawer
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                            .zIndex(5)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .top) {
            ToastOverlay()
                .padding(.top, 6)
        }
        .overlay {
            if showingCommandPalette {
                CommandPaletteView(
                    isPresented: $showingCommandPalette,
                    showingSettings: $showingSettings,
                    showWorkbench: $showWorkbench
                )
                .environmentObject(store)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView().environmentObject(store)
        }
        .onReceive(NotificationCenter.default.publisher(for: .laicaiToggleCommandPalette)) { _ in
            withAnimation(AppAnimation.spring) { showingCommandPalette.toggle() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .laicaiOpenSettings)) { _ in
            showingSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .laicaiOpenWorkbench)) { note in
            if let tab = note.object as? WorkbenchTab {
                store.selectWorkbenchTab(tab)
            }
            withAnimation(AppAnimation.spring) { showWorkbench = true }
        }
        .onChange(of: store.state.notice?.id) { _, _ in
            guard let notice = store.state.notice else { return }
            switch notice.style {
            case .info: ToastCenter.shared.show(notice.message, style: .info)
            case .success: ToastCenter.shared.success(notice.message)
            case .warning: ToastCenter.shared.warn(notice.message)
            case .error: ToastCenter.shared.error(notice.message)
            }
        }
        .onChange(of: store.state.activeConnectorID) { _, newID in
            if let id = newID, let connector = store.state.connectors.first(where: { $0.id == id }) {
                ToastCenter.shared.success("已切换到 \(connector.name)")
            }
        }
        .onChange(of: showSidebar) { _, newVal in
            withAnimation(AppAnimation.spring) { sidebarExpanded = newVal }
            NotificationCenter.default.post(name: .laicaiPanelToggled, object: nil)
        }
        .onChange(of: showWorkbench) { _, _ in
            NotificationCenter.default.post(name: .laicaiPanelToggled, object: nil)
        }
    }

    private var workbenchDrawer: some View {
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(AppAnimation.spring) { showWorkbench = false }
                }

            VStack(spacing: 0) {
                HStack {
                    Text("工具面板")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TextGrade.secondary)
                    Spacer()
                    ToolbarButton(icon: "xmark", tooltip: "关闭面板") {
                        withAnimation(AppAnimation.spring) { showWorkbench = false }
                    }
                }
                .padding(.horizontal, AppSpace.medium)
                .padding(.vertical, AppSpace.extraSmall)
                .background(SurfaceGrade.panel)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(SurfaceGrade.divider.opacity(0.5)).frame(height: 0.5)
                }

                WorkbenchView()
            }
            .frame(width: LayoutConst.workbenchPanelIdealWidth)
            .background(SurfaceGrade.panel)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(SurfaceGrade.divider.opacity(0.58))
                    .frame(width: 0.5)
            }
            .shadow(color: Color.black.opacity(0.10), radius: 22, x: -8, y: 0)
        }
        .background(Color.black.opacity(0.035))
    }

    private var workspaceBackground: some View {
        ZStack {
            SurfaceGrade.base
            LinearGradient(
                colors: [
                    Color.white.opacity(0.72),
                    SurfaceGrade.base.opacity(0.95),
                    SurfaceGrade.panel.opacity(0.44),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

// MARK: - Global App Bar

private struct AppTopBar: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showingSettings: Bool
    @Binding var showSidebar: Bool
    @Binding var showWorkbench: Bool
    @Binding var showingCommandPalette: Bool
    @ObservedObject private var projectManager = ProjectManager.shared

    var body: some View {
        ZStack {
            HStack(spacing: AppSpace.medium) {
                if !showSidebar {
                    ToolbarButton(icon: "sidebar.right", tooltip: "展开导航") {
                        showSidebar.toggle()
                    }
                }

                Spacer()
                actionButtons
            }
            .padding(.horizontal, AppSpace.medium)

            titleCluster
                .frame(maxWidth: 560)
                .padding(.horizontal, 132)
        }
        .frame(height: LayoutConst.toolbarHeight)
        .background(SurfaceGrade.card.opacity(0.96))
    }

    private var titleCluster: some View {
        VStack(alignment: .center, spacing: 2) {
            HStack(spacing: AppSpace.small) {
                Text(currentTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TextGrade.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let thread = store.state.selectedThread {
                    Image(systemName: agentIcon(for: thread))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(threadTint(thread))
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: AppSpace.small) {
                Text(subtitle)
                    .font(AppFont.tiny)
                    .foregroundStyle(store.hasRunningGenerationTasks ? Semantic.toolRunning : TextGrade.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let project = selectedThreadProjectName {
                    Text("· \(project)")
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.ghost)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .allowsHitTesting(false)
    }

    private var actionButtons: some View {
        HStack(spacing: AppSpace.extraSmall) {
            ToolbarButton(icon: "hammer", tooltip: "新任务") {
                startNewTask()
            }

            ToolbarButton(icon: "plus.message", tooltip: "新会话") {
                store.newThread()
            }

            ToolbarButton(icon: "command", tooltip: "命令面板") {
                showingCommandPalette = true
            }

            ToolbarButton(icon: showWorkbench ? "sidebar.trailing" : "sidebar.trailing", tooltip: showWorkbench ? "隐藏工具面板" : "显示工具面板") {
                withAnimation(AppAnimation.spring) { showWorkbench.toggle() }
            }

            ToolbarButton(icon: "gearshape", tooltip: "设置") {
                showingSettings = true
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func startNewTask() {
        if let projectID = projectManager.activeProjectID {
            store.newThreadInProject(projectID)
        } else {
            store.newThread()
        }
        store.updateDraft("请直接处理这个目标：")
    }

    private var currentTitle: String {
        guard let thread = store.state.selectedThread else { return "工作台" }
        let title = TextHelper.compactTitle(thread.title)
        return title.isEmpty ? "新会话" : title
    }

    private var subtitle: String {
        if let threadID = store.state.selectedThreadID, store.isThreadGenerating(threadID) {
            let live = store.liveActivity(for: threadID).trimmingCharacters(in: .whitespacesAndNewlines)
            return live.isEmpty ? "正在运行" : live
        }
        if store.hasRunningGenerationTasks {
            return "后台会话运行中"
        }
        guard let thread = store.state.selectedThread else { return "选择会话，或直接输入一个目标" }
        return "\(thread.executionState.title) · \(RelativeTimeFormatter.string(for: thread.updatedAt))"
    }

    private var selectedThreadProjectName: String? {
        guard let projectID = store.state.selectedThread?.projectID,
            let project = projectManager.projects.first(where: { $0.id == projectID })
        else {
            return nil
        }
        return project.name
    }

    private func threadTint(_ thread: Thread) -> Color {
        if store.isThreadGenerating(thread.id) { return Semantic.toolRunning }
        switch thread.executionState {
        case .running, .planning: return Semantic.toolRunning
        case .waitingForApproval: return Semantic.warning
        case .blocked, .failed: return Semantic.error
        case .paused: return TextGrade.muted
        case .completed: return Semantic.success
        case .idle, .archived: return Brand.primary
        }
    }

    private func agentIcon(for thread: Thread) -> String {
        switch thread.executionState {
        case .running: return "waveform.path.ecg"
        case .planning: return "brain.head.profile"
        case .waitingForApproval: return "eye"
        case .blocked, .failed: return "xmark.circle"
        case .paused: return "pause.circle"
        case .completed: return "checkmark.circle"
        case .archived: return "archivebox"
        case .idle: return "person.crop.circle.badge.gearshape"
        }
    }

    private func topMetaChip(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(AppFont.tiny)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
    }
}

// MARK: - Status Bar

struct StatusBarView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpace.medium) {
                Spacer()

                if store.hasRunningGenerationTasks {
                    HStack(spacing: AppSpace.extraSmall) {
                        ProgressView()
                            .scaleEffect(0.55)
                            .frame(width: 12, height: 12)
                        Text("运行中")
                    }
                    .foregroundStyle(Brand.jade)
                }

                // Right: command palette hint
                HStack(spacing: AppSpace.medium) {
                    Text("⌘K")
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(SurfaceGrade.card)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(SurfaceGrade.border.opacity(0.7), lineWidth: 0.5)
                                )
                        )
                }
            }
            .statusBarStyle()
            .padding(.horizontal, AppSpace.large)
            .frame(height: LayoutConst.statusBarHeight)
            .background(SurfaceGrade.panel)
            .overlay(alignment: .top) {
                Rectangle().fill(SurfaceGrade.divider.opacity(0.58)).frame(height: 0.5)
            }
        }
    }
}
