import AppKit
import SwiftUI
import LaicaiNativeDomain
import LaicaiNativeFoundation

struct CommandPaletteView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var isPresented: Bool
    @Binding var showingSettings: Bool
    @Binding var showWorkbench: Bool
    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var keyMonitor: Any?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 0) {
                HStack(spacing: AppSpace.md) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(TextGrade.muted)
                    TextField("输入命令或搜索 Agent...", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(TextGrade.primary)
                        .focused($isSearchFocused)
                    Text("Esc")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(TextGrade.ghost)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                                .fill(SurfaceGrade.elevated)
                                .overlay(
                                    RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                                        .strokeBorder(SurfaceGrade.divider, lineWidth: 0.5)
                                )
                        )
                }
                .padding(.horizontal, AppSpace.xl)
                .padding(.vertical, AppSpace.lg)

                Rectangle().fill(SurfaceGrade.divider).frame(height: 0.5)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !matchingThreads.isEmpty {
                            CommandPaletteSectionTitle("Agent")
                            ForEach(matchingThreads) { thread in
                                Button {
                                    open(thread)
                                } label: {
                                    CommandPaletteThreadRow(thread: thread)
                                }
                                .buttonStyle(.plain)
                            }
                            if !filteredActions.isEmpty {
                                CommandPaletteSectionTitle("命令")
                            }
                        }

                        ForEach(Array(filteredActions.enumerated()), id: \.element.id) { index, action in
                            Button {
                                run(action)
                            } label: {
                                CommandPaletteRow(action: action, isSelected: index == selectedIndex)
                            }
                            .buttonStyle(.plain)
                            .onTapGesture {
                                selectedIndex = index
                                run(action)
                            }
                        }

                        if filteredActions.isEmpty && matchingThreads.isEmpty {
                            Text("没有匹配的命令或 Agent")
                                .font(AppFont.caption)
                                .foregroundStyle(TextGrade.muted)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(AppSpace.xl)
                        }
                    }
                    .padding(.vertical, AppSpace.xs)
                }
                .frame(maxHeight: 420)
            }
            .frame(width: 540)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .fill(SurfaceGrade.panel)
            )
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .strokeBorder(SurfaceGrade.border.opacity(0.4), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.5), radius: 40, y: 16)
        }
        .onExitCommand { isPresented = false }
        .onChange(of: query) { _ in
            selectedIndex = 0
        }
        .onAppear {
            isSearchFocused = true
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard self.isPresented else { return event }
                    switch event.keyCode {
                    case 125: // down arrow
                        self.selectedIndex = min(self.selectedIndex + 1, max(self.filteredActions.count - 1, 0))
                        return nil
                    case 126: // up arrow
                        self.selectedIndex = max(self.selectedIndex - 1, 0)
                        return nil
                    case 36: // return
                        guard !self.filteredActions.isEmpty else { return event }
                        if self.selectedIndex < self.filteredActions.count {
                            self.run(self.filteredActions[self.selectedIndex])
                        }
                        return nil
                    default:
                        return event
                    }
                }
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
    }

    private var filteredActions: [CommandPaletteAction] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return actions }
        return actions.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || $0.subtitle.localizedCaseInsensitiveContains(needle)
                || $0.keywords.contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    private var matchingThreads: [ThreadRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return store.state.threadSummaries
            .filter { thread in
                thread.title.localizedCaseInsensitiveContains(needle)
                    || thread.preview.localizedCaseInsensitiveContains(needle)
                    || thread.source.rawValue.localizedCaseInsensitiveContains(needle)
                    || thread.status?.title.localizedCaseInsensitiveContains(needle) == true
            }
            .prefix(8)
            .map { $0 }
    }

    private var actions: [CommandPaletteAction] {
        var result: [CommandPaletteAction] = [
            .init(kind: .newThread, icon: "square.and.pencil", title: "新 Agent", subtitle: "开始一个干净的 Agent", keywords: ["new", "thread", "agent"]),
            .init(kind: .search, icon: "magnifyingglass", title: "搜索 Agent", subtitle: "打开侧栏搜索", keywords: ["find", "search", "agent"]),
            .init(kind: .toggleWorkbench, icon: "sidebar.right", title: "打开 Agent 检查器", subtitle: "查看右侧 Agent 状态、计划和模型连接", keywords: ["workbench", "panel", "agent"]),
            .init(kind: .settings, icon: "gearshape", title: "设置", subtitle: "模型、工作区与运行配置", keywords: ["settings", "model"])
        ]

        if store.state.selectedThread?.canContinueAgent == true {
            result.insert(.init(kind: .continueTask, icon: "arrow.turn.down.right", title: "继续当前 Agent", subtitle: "沿用这个 Agent 的已读信息", keywords: ["continue", "resume", "agent"]), at: 1)
        }
        if store.state.selectedThread != nil {
            result.append(.init(kind: .copyMarkdown, icon: "doc.on.doc", title: "复制当前 Agent Markdown", subtitle: "导出可读记录", keywords: ["copy", "export", "markdown"]))
            result.append(.init(kind: .exportJSON, icon: "square.and.arrow.up", title: "导出当前 Agent JSON", subtitle: "导出完整结构化记录", keywords: ["export", "json"]))
            result.append(.init(kind: .exportShellScript, icon: "terminal", title: "导出为 Shell 脚本", subtitle: "提取所有 shell 命令为可运行脚本", keywords: ["export", "shell", "bash", "script"]))
            result.append(.init(kind: .exportWorkflowYAML, icon: "arrow.triangle.branch", title: "导出为工作流 YAML", subtitle: "将 Agent 步骤转为可重放工作流", keywords: ["export", "workflow", "yaml"]))
            result.append(.init(kind: .archiveThread, icon: "archivebox", title: "归档当前 Agent", subtitle: "从侧栏隐藏", keywords: ["archive", "hide"]))
        }
        if store.state.selectedThread?.canContinueAgent == true {
            result.append(.init(kind: .copyEvidence, icon: "checklist", title: "复制证据清单", subtitle: "导出已读文件、工具和验证状态", keywords: ["evidence", "verify", "proof"]))
        }
        if store.state.activeConnector != nil {
            result.append(.init(kind: .testModel, icon: "waveform.path.ecg", title: "测试当前模型", subtitle: store.state.activeConnector?.name ?? "当前连接器", keywords: ["health", "connector"]))
        }
        if store.state.selectedThread?.steps.isEmpty == false {
            result.append(.init(kind: .retry, icon: "arrow.clockwise", title: "重试最近请求", subtitle: "重新执行最后一条用户输入", keywords: ["retry"]))
        }

        // Connector switching
        for connector in store.state.connectors.prefix(6) {
            let isActive = connector.id == store.state.activeConnectorID
            result.append(.init(
                kind: .switchConnector(connector.id),
                icon: isActive ? "checkmark.circle.fill" : "circle",
                title: "切换到 \(connector.name)",
                subtitle: connector.kind,
                keywords: ["connector", "model", connector.name]
            ))
        }

        // Project switching
        let projects = ProjectManager.shared.projects
        if projects.count > 1 {
            for project in projects.prefix(6) {
                let isActive = project.id == ProjectManager.shared.activeProjectID
                result.append(.init(
                    kind: .switchProject(project.rootPath),
                    icon: isActive ? "folder.fill" : "folder",
                    title: "项目：\(project.name)",
                    subtitle: project.techStack.prefix(3).joined(separator: ", "),
                    keywords: ["project", "项目", project.name]
                ))
            }
        }

        // PM Agent shortcuts
        let pmSkills: [(PMSkillType, String)] = [
            (.prd, "写 PRD"),
            (.userStories, "写用户故事"),
            (.competitiveAnalysis, "竞品分析"),
            (.experimentDesign, "实验设计"),
            (.retrospective, "项目复盘"),
            (.persona, "用户画像"),
            (.okrWriter, "写 OKR"),
        ]
        for (skill, title) in pmSkills {
            result.append(.init(
                kind: .pmAgent(skill.rawValue),
                icon: skill.icon,
                title: "PM：\(title)",
                subtitle: "[\(skill.phase)] \(skill.displayName)",
                keywords: ["pm", "product", skill.rawValue, skill.displayName]
            ))
        }

        // Skill shortcuts
        let skillRegistry = SkillRegistry.shared
        for skill in skillRegistry.skills.filter({ !$0.tools.isEmpty || $0.workflowName != nil }).prefix(8) {
            result.append(.init(
                kind: .runSkill(skill.name),
                icon: "sparkles",
                title: "技能：\(skill.name)",
                subtitle: skill.description,
                keywords: ["skill", skill.name]
            ))
        }

        return result
    }

    private func run(_ action: CommandPaletteAction) {
        switch action.kind {
        case .newThread:
            store.newTask()
        case .continueTask:
            if let agent = store.state.selectedThread {
                store.continueAgent(id: agent.id)
            }
        case .search:
            NotificationCenter.default.post(name: .laicaiToggleSearch, object: nil)
        case .toggleWorkbench:
            showWorkbench.toggle()
        case .settings:
            showingSettings = true
        case .copyMarkdown:
            if let markdown = store.exportSelectedThreadMarkdown() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(markdown, forType: .string)
                ToastCenter.shared.success("已复制当前 Agent")
            }
        case .copyEvidence:
            if let markdown = store.exportSelectedTaskEvidenceMarkdown() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(markdown, forType: .string)
                ToastCenter.shared.success("已复制证据清单")
            }
        case .testModel:
            if let id = store.state.activeConnectorID {
                store.checkConnectorHealth(id: id)
                ToastCenter.shared.show("正在测试当前模型")
            }
        case .retry:
            store.retryLastMessage()
        case .switchConnector(let id):
            store.selectConnector(id: id)
            ToastCenter.shared.success("已切换连接器")
        case .runSkill(let name):
            if let skill = SkillRegistry.shared.skills.first(where: { $0.name == name }) {
                var template = ""
                if let workflow = skill.workflowName {
                    template = "请执行\(workflow)工作流"
                } else if !skill.tools.isEmpty {
                    template = "请使用\(skill.tools.joined(separator: "、"))处理以下目标："
                }
                if !template.isEmpty {
                    store.updateDraft(template)
                }
            }
        case .archiveThread:
            if let threadID = store.state.selectedThread?.id {
                store.archiveThread(id: threadID)
                ToastCenter.shared.success("已归档")
            }
        case .exportJSON:
            if let json = store.exportSelectedThreadJSON() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(json, forType: .string)
                ToastCenter.shared.success("已导出 JSON")
            }
        case .exportShellScript:
            if let script = store.exportSelectedThreadShellScript() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(script, forType: .string)
                ToastCenter.shared.success("已复制 Shell 脚本")
            } else {
                ToastCenter.shared.error("当前 Agent 无 shell 命令")
            }
        case .exportWorkflowYAML:
            if let yaml = store.exportSelectedThreadWorkflowYAML() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(yaml, forType: .string)
                ToastCenter.shared.success("已复制工作流 YAML")
            } else {
                ToastCenter.shared.error("当前 Agent 无工具调用")
            }
        case .pmAgent(let skillName):
            let skill = PMSkillType(rawValue: skillName) ?? .prd
            store.updateDraft("帮我写一份\(skill.displayName)，主题：")
            ToastCenter.shared.success("PM Agent：\(skill.displayName)")
        case .switchProject(let path):
            store.switchWorkspace(to: path)
            let name = URL(fileURLWithPath: path).lastPathComponent
            ToastCenter.shared.success("已切换到项目：\(name)")
        }
        isPresented = false
    }

    private func open(_ thread: ThreadRecord) {
        store.selectAgent(id: thread.id)
        isPresented = false
    }
}

private struct CommandPaletteSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(AppFont.tiny)
            .foregroundStyle(TextGrade.ghost)
            .padding(.horizontal, AppSpace.lg)
            .padding(.top, AppSpace.sm)
            .padding(.bottom, AppSpace.xs)
    }
}

private struct CommandPaletteRow: View {
    let action: CommandPaletteAction
    var isSelected: Bool = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: AppSpace.sm) {
            Image(systemName: action.icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Brand.primary : TextGrade.muted)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                    .font(AppFont.body)
                    .foregroundStyle(TextGrade.primary)
                Text(action.subtitle)
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, AppSpace.lg)
        .padding(.vertical, AppSpace.xs + 2)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                .fill(isSelected ? Brand.primary.opacity(0.08) : (isHovered ? SurfaceGrade.hover : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { h in withAnimation(AppAnimation.micro) { isHovered = h } }
    }
}

private struct CommandPaletteThreadRow: View {
    let thread: ThreadRecord
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: AppSpace.sm) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(thread.title)
                    .font(AppFont.body)
                    .foregroundStyle(TextGrade.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, AppSpace.lg)
        .padding(.vertical, AppSpace.xs + 2)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                .fill(isHovered ? SurfaceGrade.hover : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { h in withAnimation(AppAnimation.micro) { isHovered = h } }
    }

    private var subtitle: String {
        let type = "Agent"
        let status = thread.status.map { " · \($0.title)" } ?? ""
        let preview = thread.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.isEmpty ? "\(type)\(status)" : "\(type)\(status) · \(preview)"
    }

    private var icon: String {
        if let status = thread.status { return status.icon }
        return thread.isPinned ? "pin.fill" : "text.bubble"
    }

    private var tint: Color {
        if let status = thread.status { return status.color }
        return thread.isPinned ? Semantic.warning : Brand.primary
    }
}

private struct CommandPaletteAction: Identifiable {
    let id = UUID()
    var kind: CommandPaletteActionKind
    var icon: String
    var title: String
    var subtitle: String
    var keywords: [String]
}

private enum CommandPaletteActionKind {
    case newThread
    case continueTask
    case search
    case toggleWorkbench
    case settings
    case copyMarkdown
    case copyEvidence
    case testModel
    case retry
    case switchConnector(UUID)
    case runSkill(String)
    case archiveThread
    case exportJSON
    case exportShellScript
    case exportWorkflowYAML
    case pmAgent(String)  // PM skill name
    case switchProject(String)  // project root path
}
