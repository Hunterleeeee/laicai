import SwiftUI
import LaicaiNativeDomain
import LaicaiNativeFoundation

// MARK: - Agents Panel (Agent Hub)

struct AgentsPanel: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var agentReg = AgentRegistry.shared
    @ObservedObject private var toolReg = CustomToolRegistry.shared
    @State private var showAgentSheet = false
    @State private var showToolSheet = false
    @State private var editingAgent: CustomAgentDefinition?
    @State private var editingTool: CustomToolDefinition?
    @State private var expandedRole: AgentRole?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.xl) {
            builtinRolesSection
            dividerLine
            collaborationSection
            dividerLine
            customAgentSection
            dividerLine
            customToolSection
        }
        .onAppear {
            agentReg.refresh(workspaceRoot: store.state.settings.workspacePath)
            toolReg.refresh(workspaceRoot: store.state.settings.workspacePath)
        }
        .onChange(of: store.state.settings.workspacePath) { v in
            agentReg.refresh(workspaceRoot: v)
            toolReg.refresh(workspaceRoot: v)
        }
        .sheet(isPresented: $showAgentSheet, onDismiss: { editingAgent = nil }) {
            AgentEditorSheet(
                agent: editingAgent,
                toolNames: toolReg.allToolNames(),
                workspaceRoot: store.state.settings.workspacePath,
                connectorID: store.state.activeConnectorID,
                onSave: { saved in
                    do {
                        if editingAgent != nil {
                            try agentReg.update(saved, workspaceRoot: store.state.settings.workspacePath)
                        } else {
                            _ = try agentReg.create(
                                name: saved.name, role: saved.role,
                                systemPrompt: saved.systemPrompt, tools: saved.tools,
                                preferredConnectorID: saved.preferredConnectorID,
                                workspaceRoot: store.state.settings.workspacePath
                            )
                        }
                        ToastCenter.shared.success("已保存 Agent「\(saved.name)」")
                    } catch { ToastCenter.shared.error(error.localizedDescription) }
                    showAgentSheet = false
                }
            )
            .frame(minWidth: 500, minHeight: 540)
        }
        .sheet(isPresented: $showToolSheet, onDismiss: { editingTool = nil }) {
            ToolEditorSheet(
                tool: editingTool,
                workspaceRoot: store.state.settings.workspacePath,
                onSave: { saved in
                    do {
                        if editingTool != nil {
                            try toolReg.update(saved, workspaceRoot: store.state.settings.workspacePath)
                        } else {
                            _ = try toolReg.create(saved, workspaceRoot: store.state.settings.workspacePath)
                        }
                        ToastCenter.shared.success("已保存工具「\(saved.name)」")
                    } catch { ToastCenter.shared.error(error.localizedDescription) }
                    showToolSheet = false
                }
            )
            .frame(minWidth: 460, minHeight: 420)
        }
    }

    private var dividerLine: some View {
        Rectangle().fill(SurfaceGrade.divider).frame(height: 1).padding(.horizontal, -AppSpace.md)
    }

    // MARK: - 1. Built-in Roles Catalog

    private var builtinRolesSection: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            sectionHeader(icon: "person.3.fill", color: Brand.primary, title: "内置角色", subtitle: "5 种专业角色，自动按任务分配")

            VStack(spacing: AppSpace.xs) {
                ForEach(AgentRole.allCases) { role in
                    builtinRoleCard(role)
                }
            }
        }
    }

    private func builtinRoleCard(_ role: AgentRole) -> some View {
        let isExpanded = expandedRole == role
        let color = Self.roleColor(for: role)
        let desc = Self.roleDescription(for: role)
        let tools = Array(role.allowedTools).sorted()

        return VStack(alignment: .leading, spacing: 0) {
            // Header row (always visible)
            HStack(spacing: AppSpace.md) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.25), color.opacity(0.06)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 32, height: 32)
                    Image(systemName: role.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(color)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(role.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TextGrade.primary)
                    Text(desc)
                        .font(.system(size: 10))
                        .foregroundStyle(TextGrade.muted)
                        .lineLimit(isExpanded ? nil : 1)
                }

                Spacer()

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(TextGrade.ghost)
            }
            .padding(10)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(AppAnimation.quick) {
                    expandedRole = isExpanded ? nil : role
                }
            }

            // Expanded detail
            if isExpanded {
                VStack(alignment: .leading, spacing: AppSpace.sm) {
                    // Tools
                    Text("可用工具")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(TextGrade.ghost)
                        .textCase(.uppercase)

                    FlowLayout(spacing: 4) {
                        ForEach(tools, id: \.self) { tool in
                            Text(tool)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(color)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(color.opacity(0.08))
                                )
                        }
                    }

                    // Capabilities
                    Text("典型任务")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(TextGrade.ghost)
                        .textCase(.uppercase)
                        .padding(.top, 4)

                    ForEach(Self.roleCapabilities(for: role), id: \.self) { cap in
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(color.opacity(0.4))
                                .frame(width: 4, height: 4)
                                .padding(.top, 4)
                            Text(cap)
                                .font(.system(size: 10))
                                .foregroundStyle(TextGrade.secondary)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .padding(.leading, 44)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(isExpanded ? color.opacity(0.03) : SurfaceGrade.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(isExpanded ? color.opacity(0.15) : SurfaceGrade.border.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - 2. Collaboration Flow Templates

    private var collaborationSection: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            sectionHeader(icon: "arrow.triangle.branch", color: Color(hex: "8B5CF6"), title: "协作模板", subtitle: "预设的多 Agent 协作流水线")

            VStack(spacing: AppSpace.sm) {
                ForEach(PlanTemplate.templates) { tpl in
                    collaborationCard(tpl)
                }
            }

            // Trigger keywords
            VStack(alignment: .leading, spacing: AppSpace.sm) {
                HStack(spacing: AppSpace.xs) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 9))
                        .foregroundStyle(TextGrade.ghost)
                    Text("触发多 Agent 协作的关键词")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TextGrade.muted)
                }

                FlowLayout(spacing: 4) {
                    ForEach(Self.triggerKeywords, id: \.self) { kw in
                        Text(kw)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Brand.primary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Brand.primary.opacity(0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(Brand.primary.opacity(0.12), lineWidth: 0.5)
                            )
                    }
                }

                Text("在输入中包含这些关键词，系统自动激活多 Agent 协作")
                    .font(.system(size: 9))
                    .foregroundStyle(TextGrade.ghost)
            }
            .padding(AppSpace.md)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .fill(SurfaceGrade.panel.opacity(0.4))
            )
        }
    }

    private func collaborationCard(_ template: PlanTemplate) -> some View {
        VStack(alignment: .leading, spacing: AppSpace.sm) {
            HStack(spacing: AppSpace.sm) {
                Image(systemName: template.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(hex: "8B5CF6"))
                Text(template.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TextGrade.primary)
                Spacer()
                Text("\(template.roles.count) Agent")
                    .font(.system(size: 9))
                    .foregroundStyle(TextGrade.ghost)
            }

            // Visual flow: role → role → role
            HStack(spacing: 0) {
                ForEach(Array(template.roles.enumerated()), id: \.offset) { idx, role in
                    let color = Self.roleColor(for: role)
                    HStack(spacing: 4) {
                        Image(systemName: role.icon)
                            .font(.system(size: 9, weight: .medium))
                        Text(role.title)
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(color.opacity(0.08))
                    )

                    if idx < template.roles.count - 1 {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(TextGrade.ghost)
                            .padding(.horizontal, 3)
                    }
                }
            }

            Text(template.description)
                .font(.system(size: 10))
                .foregroundStyle(TextGrade.muted)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(SurfaceGrade.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(SurfaceGrade.border.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - 3. Custom Agents

    private var customAgentSection: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            HStack(spacing: AppSpace.sm) {
                sectionHeader(icon: "person.crop.circle.badge.plus", color: Semantic.success, title: "自定义 Agent", subtitle: agentReg.agents.isEmpty ? "基于内置角色创建专属 Agent" : "\(agentReg.agents.count) 个")
                Spacer()
                Button { editingAgent = nil; showAgentSheet = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                        Text("新建").font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(Brand.primary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Brand.primary.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(Brand.primary.opacity(0.15), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }

            if agentReg.agents.isEmpty {
                Text("点击「新建」创建自定义 Agent，设定角色、提示词和工具集")
                    .font(.system(size: 10))
                    .foregroundStyle(TextGrade.ghost)
                    .padding(.vertical, AppSpace.md)
                    .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: AppSpace.sm) {
                    ForEach(agentReg.agents) { agent in
                        AgentCard(agent: agent, onEdit: {
                            editingAgent = agent; showAgentSheet = true
                        }, onChat: {
                            store.updateDraft("[Agent: \(agent.name)] ")
                        }, onDelete: {
                            agentReg.delete(agent, workspaceRoot: store.state.settings.workspacePath)
                        })
                    }
                }
            }
        }
    }

    // MARK: - 4. Custom Tools

    private var customToolSection: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            HStack(spacing: AppSpace.sm) {
                sectionHeader(icon: "wrench.and.screwdriver", color: Semantic.warning, title: "自定义工具", subtitle: toolReg.tools.isEmpty ? "Shell · HTTP · 脚本" : "\(toolReg.tools.count) 个")
                Spacer()
                Button { editingTool = nil; showToolSheet = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                        Text("新建").font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(Semantic.warning)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Semantic.warning.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(Semantic.warning.opacity(0.15), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }

            if toolReg.tools.isEmpty {
                Text("创建工具后，Agent 可在任务中自动调用")
                    .font(.system(size: 10))
                    .foregroundStyle(TextGrade.ghost)
                    .padding(.vertical, AppSpace.sm)
                    .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: AppSpace.xs) {
                    ForEach(toolReg.tools) { tool in
                        ToolCard(tool: tool, onEdit: {
                            editingTool = tool; showToolSheet = true
                        }, onDelete: {
                            toolReg.delete(tool, workspaceRoot: store.state.settings.workspacePath)
                        })
                    }
                }
            }

            HStack(spacing: 4) {
                Image(systemName: "folder").font(.system(size: 8))
                Text(".laicai/tools/*.json").font(.system(size: 9, design: .monospaced))
            }
            .foregroundStyle(TextGrade.ghost)
        }
    }

    // MARK: - Shared helpers

    private func sectionHeader(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: AppSpace.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color.opacity(0.1))
                    .frame(width: 24, height: 24)
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TextGrade.primary)
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(TextGrade.ghost)
            }
        }
    }

    static func roleColor(for role: AgentRole) -> Color {
        switch role {
        case .coder: return Color(hex: "10B981")
        case .reviewer: return Color(hex: "F59E0B")
        case .researcher: return Color(hex: "3B82F6")
        case .tester: return Color(hex: "8B5CF6")
        case .planner: return Color(hex: "06B6D4")
        }
    }

    private static func roleDescription(for role: AgentRole) -> String {
        switch role {
        case .planner: return "分析复杂任务并拆解为可执行步骤，制定实施计划"
        case .coder: return "读写代码、执行命令、使用 Git，完成具体的编码实现"
        case .reviewer: return "审查代码质量、逻辑正确性和潜在风险"
        case .researcher: return "搜索代码库和网络，收集信息并整理调研结果"
        case .tester: return "运行测试、验证功能正确性，报告测试结果"
        }
    }

    private static func roleCapabilities(for role: AgentRole) -> [String] {
        switch role {
        case .planner: return ["拆解复杂任务为子步骤", "分析项目结构和依赖", "制定实施计划和优先级", "评估风险和可行性"]
        case .coder: return ["读写和修改源代码", "执行 Shell 命令和脚本", "Git 提交和分支操作", "构建验证和错误修复"]
        case .reviewer: return ["检查代码逻辑和风格", "发现潜在 bug 和安全隐患", "对比 Git 变更和差异", "提出改进建议"]
        case .researcher: return ["搜索代码库中的函数和类", "联网查找技术方案", "整理 API 文档和用例", "对比不同实现方案"]
        case .tester: return ["运行单元测试和集成测试", "验证构建是否通过", "模拟边界条件和异常", "生成测试报告"]
        }
    }

    static let triggerKeywords = [
        "协同", "多agent", "先…然后…",
        "审查并修复", "写代码并测试",
        "搜索然后实现", "重构并验证",
        "全面", "完整", "端到端",
    ]
}
// MARK: - Agent Card

private struct AgentCard: View {
    let agent: CustomAgentDefinition
    let onEdit: () -> Void
    let onChat: () -> Void
    let onDelete: () -> Void
    @State private var hovered = false

    private var roleColor: Color { AgentsPanel.roleColor(for: agent.role) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: AppSpace.md) {
                // Gradient role icon
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [roleColor.opacity(0.2), roleColor.opacity(0.06)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 36, height: 36)
                    Image(systemName: agent.role.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(roleColor)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(agent.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TextGrade.primary)
                    HStack(spacing: 6) {
                        Text(agent.role.title)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(roleColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(roleColor.opacity(0.1)))
                        Text("\(agent.tools.count) 工具")
                            .font(.system(size: 9))
                            .foregroundStyle(TextGrade.muted)
                    }
                }
                Spacer()
                HStack(spacing: 4) {
                    MiniBtn(icon: "bubble.left.fill", color: Brand.primary, tip: "会话") { onChat() }
                    MiniBtn(icon: "pencil", color: TextGrade.secondary, tip: "编辑") { onEdit() }
                    MiniBtn(icon: "trash", color: Semantic.error.opacity(0.7), tip: "删除") { onDelete() }
                }
                .opacity(hovered ? 1 : 0)
            }
            // Prompt preview
            Text(agent.systemPrompt)
                .font(.system(size: 10))
                .foregroundStyle(TextGrade.muted)
                .lineLimit(2)
                .padding(.leading, 48)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .fill(hovered ? SurfaceGrade.hover : SurfaceGrade.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(hovered ? roleColor.opacity(0.2) : SurfaceGrade.border.opacity(0.12), lineWidth: hovered ? 1 : 0.5)
        )
        .shadow(color: hovered ? roleColor.opacity(0.06) : .clear, radius: 8, y: 2)
        .onHover { hovered = $0 }
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
    }
}

// MARK: - Tool Card

private struct ToolCard: View {
    let tool: CustomToolDefinition
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovered = false

    private var modeIcon: String {
        switch tool.executionMode {
        case .shell: return "terminal"
        case .http: return "globe"
        case .script: return "doc.text"
        }
    }

    private var modeLabel: String {
        switch tool.executionMode {
        case .shell: return "Shell"
        case .http: return "HTTP"
        case .script: return "Script"
        }
    }

    var body: some View {
        HStack(spacing: AppSpace.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Semantic.warning.opacity(0.1))
                    .frame(width: 32, height: 32)
                Image(systemName: modeIcon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Semantic.warning)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.qualifiedName)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(TextGrade.primary)
                    Text(modeLabel)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Semantic.warning.opacity(0.8))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Semantic.warning.opacity(0.08)))
                }
                Text(tool.description)
                    .font(.system(size: 10))
                    .foregroundStyle(TextGrade.muted)
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 4) {
                MiniBtn(icon: "pencil", color: TextGrade.secondary, tip: "编辑") { onEdit() }
                MiniBtn(icon: "trash", color: Semantic.error.opacity(0.7), tip: "删除") { onDelete() }
            }
            .opacity(hovered ? 1 : 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(hovered ? SurfaceGrade.hover : SurfaceGrade.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(hovered ? Semantic.warning.opacity(0.15) : SurfaceGrade.border.opacity(0.08), lineWidth: 0.5)
        )
        .onHover { hovered = $0 }
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
    }
}

private struct MiniBtn: View {
    let icon: String; let color: Color; let tip: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 24, height: 24)
                .background(Circle().fill(SurfaceGrade.elevated.opacity(0.4)))
                .contentShape(Circle())
        }.buttonStyle(.plain).help(tip)
    }
}

// MARK: - Agent Editor Sheet

private struct AgentEditorSheet: View {
    let agent: CustomAgentDefinition?
    let toolNames: [String]
    let workspaceRoot: String
    let connectorID: UUID?
    let onSave: (CustomAgentDefinition) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var role: AgentRole = .coder
    @State private var prompt = ""
    @State private var selectedTools: Set<String> = []

    private static let promptTemplates: [(String, String)] = [
        ("通用助手", "你是{{name}}，一个专业的{{role}}。请根据用户需求完成任务，注重质量和效率。"),
        ("代码专家", "你是{{name}}，精通多种编程语言。分析代码时关注：架构设计、性能、安全性、可维护性。输出简洁、可执行的方案。"),
        ("研究分析", "你是{{name}}，负责深度研究和信息整合。先搜索、再验证、最后归纳。确保结论有数据支撑，标注来源。"),
        ("严格审查", "你是{{name}}，负责代码审查。逐行检查变更，关注：逻辑错误、边界情况、风格一致性、安全漏洞。给出具体修改建议。"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView { form.padding(20) }
            footer
        }
        .background(SurfaceGrade.base)
        .onAppear { loadAgent() }
    }

    private var header: some View {
        HStack {
            Text(agent == nil ? "新建 Agent" : "编辑 Agent")
                .font(AppFont.headline).foregroundStyle(TextGrade.primary)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(TextGrade.muted)
                    .frame(width: 24, height: 24).background(Circle().fill(SurfaceGrade.elevated))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(SurfaceGrade.divider).frame(height: 1) }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            fieldSection("基本信息") {
                TextField("Agent 名称", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(AppFont.body)

                HStack(spacing: 12) {
                    ForEach(AgentRole.allCases) { r in
                        Button {
                            role = r
                            if selectedTools.isEmpty { selectedTools = role.allowedTools }
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: r.icon)
                                    .font(.system(size: 14, weight: role == r ? .semibold : .regular))
                                Text(r.title).font(.system(size: 9))
                            }
                            .foregroundStyle(role == r ? Brand.primary : TextGrade.muted)
                            .frame(width: 52, height: 48)
                            .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(role == r ? Brand.primaryMuted : SurfaceGrade.card))
                            .overlay(RoundedRectangle(cornerRadius: AppRadius.md).strokeBorder(role == r ? Brand.primary.opacity(0.3) : Color.clear, lineWidth: 1))
                        }.buttonStyle(.plain)
                    }
                }
            }

            fieldSection("系统提示词") {
                HStack(spacing: 6) {
                    ForEach(Self.promptTemplates, id: \.0) { tpl in
                        Button(tpl.0) {
                            prompt = tpl.1
                                .replacingOccurrences(of: "{{name}}", with: name.isEmpty ? "Agent" : name)
                                .replacingOccurrences(of: "{{role}}", with: role.title)
                        }
                        .font(AppFont.tiny)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: AppRadius.sm).fill(SurfaceGrade.elevated))
                        .buttonStyle(.plain)
                    }
                }

                ZStack(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("输入系统提示词…\n支持变量：{{goal}} {{context}} {{workspace}}")
                            .font(AppFont.caption).foregroundStyle(TextGrade.ghost)
                            .padding(8)
                    }
                    TextEditor(text: $prompt)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 120)
                }
                .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(SurfaceGrade.card))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.md).strokeBorder(SurfaceGrade.hairline, lineWidth: 0.6))
            }

            fieldSection("可用工具（\(selectedTools.count) 已选）") {
                toolSelectionGrid
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            Spacer()
            Button(agent == nil ? "创建" : "保存") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(SurfaceGrade.divider).frame(height: 1) }
    }

    private var toolSelectionGrid: some View {
        let grouped = Dictionary(grouping: toolNames) { (name: String) -> String in
            if name.hasPrefix("custom.") { return "自定义" }
            let p = name.split(separator: ".").first.map(String.init) ?? ""
            switch p {
            case "file": return "文件"
            case "code", "workspace": return "搜索"
            case "web": return "网络"
            case "shell", "verify": return "执行"
            default: return "其他"
            }
        }
        let order = ["文件", "搜索", "网络", "执行", "自定义", "其他"]
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(order, id: \.self) { group in
                if let items = grouped[group], !items.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group).font(.system(size: 9, weight: .semibold)).foregroundStyle(TextGrade.ghost).textCase(.uppercase)
                        FlowLayout(spacing: 4) {
                            ForEach(items, id: \.self) { tool in
                                ToolChip(name: tool, isSelected: selectedTools.contains(tool)) {
                                    if selectedTools.contains(tool) { selectedTools.remove(tool) }
                                    else { selectedTools.insert(tool) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func fieldSection<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(AppFont.captionMedium).foregroundStyle(TextGrade.secondary)
            content()
        }
    }

    private func loadAgent() {
        guard let a = agent else {
            selectedTools = Set(role.allowedTools)
            return
        }
        name = a.name; role = a.role; prompt = a.systemPrompt; selectedTools = Set(a.tools)
    }

    private func save() {
        let tools = selectedTools.isEmpty ? Array(role.allowedTools).sorted() : Array(selectedTools).sorted()
        var result = agent ?? CustomAgentDefinition(name: name, role: role, systemPrompt: prompt, tools: tools, preferredConnectorID: connectorID)
        result.name = name; result.role = role; result.systemPrompt = prompt; result.tools = tools
        result.preferredConnectorID = connectorID
        onSave(result)
    }
}

// MARK: - Tool Editor Sheet

private struct ToolEditorSheet: View {
    let tool: CustomToolDefinition?
    let workspaceRoot: String
    let onSave: (CustomToolDefinition) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var desc = ""
    @State private var execMode = 0  // 0=shell, 1=http, 2=script
    @State private var shellTemplate = ""
    @State private var httpMethod = "GET"
    @State private var httpURL = ""
    @State private var scriptPath = ""
    @State private var scriptInterpreter = "python3"
    @State private var params: [CustomToolDefinition.CustomToolParam] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tool == nil ? "新建工具" : "编辑工具").font(AppFont.headline).foregroundStyle(TextGrade.primary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(TextGrade.muted)
                        .frame(width: 24, height: 24).background(Circle().fill(SurfaceGrade.elevated))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(SurfaceGrade.divider).frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("工具名称（英文，如 deploy_app）", text: $name).textFieldStyle(.roundedBorder)
                    TextField("描述", text: $desc).textFieldStyle(.roundedBorder)

                    Picker("执行方式", selection: $execMode) {
                        Text("Shell 命令").tag(0)
                        Text("HTTP 请求").tag(1)
                        Text("脚本文件").tag(2)
                    }.pickerStyle(.segmented)

                    switch execMode {
                    case 0:
                        VStack(alignment: .leading, spacing: 4) {
                            Text("命令模板（用 {{param}} 引用参数）").font(AppFont.tiny).foregroundStyle(TextGrade.muted)
                            TextField("例: curl -s {{url}} | jq .", text: $shellTemplate)
                                .font(.system(size: 12, design: .monospaced))
                                .textFieldStyle(.roundedBorder)
                        }
                    case 1:
                        HStack {
                            Picker("", selection: $httpMethod) {
                                Text("GET").tag("GET"); Text("POST").tag("POST"); Text("PUT").tag("PUT")
                            }.frame(width: 80)
                            TextField("URL 模板", text: $httpURL).textFieldStyle(.roundedBorder)
                        }
                    default:
                        HStack {
                            TextField("解释器", text: $scriptInterpreter).textFieldStyle(.roundedBorder).frame(width: 100)
                            TextField("脚本路径", text: $scriptPath).textFieldStyle(.roundedBorder)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("参数").font(AppFont.captionMedium).foregroundStyle(TextGrade.secondary)
                            Spacer()
                            Button { params.append(.init(name: "", description: "")) } label: {
                                Label("添加", systemImage: "plus").font(AppFont.tiny)
                            }.buttonStyle(.plain).foregroundStyle(Brand.primary)
                        }
                        ForEach(params.indices, id: \.self) { i in
                            HStack(spacing: 6) {
                                TextField("名称", text: $params[i].name).textFieldStyle(.roundedBorder).frame(width: 80)
                                TextField("描述", text: $params[i].description).textFieldStyle(.roundedBorder)
                                Toggle("必填", isOn: $params[i].required).toggleStyle(.checkbox)
                                Button { params.remove(at: i) } label: {
                                    Image(systemName: "minus.circle").foregroundStyle(Semantic.error)
                                }.buttonStyle(.plain)
                            }.font(AppFont.tiny)
                        }
                    }
                }
                .padding(20)
            }

            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(tool == nil ? "创建" : "保存") { saveTool() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(SurfaceGrade.divider).frame(height: 1) }
        }
        .background(SurfaceGrade.base)
        .onAppear { loadTool() }
    }

    private func loadTool() {
        guard let t = tool else { return }
        name = t.name; desc = t.description; params = t.parameters
        switch t.executionMode {
        case .shell(let tpl): execMode = 0; shellTemplate = tpl
        case .http(let m, let u, _, _): execMode = 1; httpMethod = m; httpURL = u
        case .script(let p, let i): execMode = 2; scriptPath = p; scriptInterpreter = i
        }
    }

    private func saveTool() {
        let mode: CustomToolDefinition.ExecutionMode
        switch execMode {
        case 0: mode = .shell(template: shellTemplate)
        case 1: mode = .http(method: httpMethod, urlTemplate: httpURL, headers: [:], bodyTemplate: "")
        default: mode = .script(path: scriptPath, interpreter: scriptInterpreter)
        }
        var result = tool ?? CustomToolDefinition(name: name, description: desc, parameters: params, executionMode: mode)
        result.name = name; result.description = desc; result.parameters = params; result.executionMode = mode
        onSave(result)
    }
}

// MARK: - Tool Chip

private struct ToolChip: View {
    let name: String; let isSelected: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Brand.primary : TextGrade.muted)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: AppRadius.sm).fill(isSelected ? Brand.primaryMuted : SurfaceGrade.elevated))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.sm).strokeBorder(isSelected ? Brand.primary.opacity(0.3) : Color.clear, lineWidth: 0.6))
        }.buttonStyle(.plain)
    }
}

// MARK: - Flow Layout (for tool chips)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, offset) in result.offsets.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y), proposal: .unspecified)
        }
    }
    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, offsets: [CGPoint]) {
        let maxW = proposal.width ?? .infinity
        var offsets: [CGPoint] = []
        var x: CGFloat = 0; var y: CGFloat = 0; var rowH: CGFloat = 0; var maxX: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxW && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            offsets.append(CGPoint(x: x, y: y))
            rowH = max(rowH, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }
        return (CGSize(width: maxX, height: y + rowH), offsets)
    }
}
