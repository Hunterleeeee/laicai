import SwiftUI
import LaicaiNativeDomain
import LaicaiNativeFoundation

// MARK: - Plan Templates

public struct PlanTemplate: Identifiable {
    public let id: String
    public let title: String
    public let description: String
    public let icon: String
    public let roles: [AgentRole]

    public static let templates: [PlanTemplate] = [
        PlanTemplate(
            id: "code-review",
            title: "代码审查",
            description: "研究员分析 → 审查员检查 → 编码员修复",
            icon: "eye.trianglebadge.exclamationmark",
            roles: [.researcher, .reviewer, .coder]
        ),
        PlanTemplate(
            id: "implement-test",
            title: "实现+测试",
            description: "规划员拆解 → 编码员实现 → 测试员验证",
            icon: "checkmark.shield",
            roles: [.planner, .coder, .tester]
        ),
        PlanTemplate(
            id: "full-pipeline",
            title: "完整流水线",
            description: "规划 → 编码 → 测试 → 审查",
            icon: "arrow.triangle.branch",
            roles: [.planner, .coder, .tester, .reviewer]
        ),
        PlanTemplate(
            id: "research-implement",
            title: "调研+实现",
            description: "研究员调研 → 编码员实现 → 审查员检查",
            icon: "magnifyingglass",
            roles: [.researcher, .coder, .reviewer]
        ),
        PlanTemplate(
            id: "refactor",
            title: "重构验证",
            description: "编码员重构 → 测试员验证 → 审查员检查",
            icon: "arrow.2.squarepath",
            roles: [.coder, .tester, .reviewer]
        ),
    ]
}

// MARK: - Plan Editor View

/// Interactive plan editor allowing users to customize agent plan before execution.
struct MultiAgentPlanEditorView: View {
    @Binding var plan: MultiAgentPlan
    let connectors: [ConnectorProfile]
    let workspaceRoot: String
    let onExecute: () -> Void
    let onCancel: () -> Void

    @StateObject private var agentRegistry = AgentRegistry.shared
    @State private var showTemplates = false
    @State private var draggedAgent: AgentNode?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.lg) {
            // Header
            HStack {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.primary)
                Text("编排计划")
                    .font(AppFont.headline)
                    .foregroundStyle(TextGrade.primary)

                Spacer()

                Menu {
                    if !agentRegistry.agents.isEmpty {
                        Section("自定义 Agent") {
                            ForEach(agentRegistry.agents) { agent in
                                Button {
                                    withAnimation(AppAnimation.quick) {
                                        plan.addAgent(agent.makeNode(), after: plan.agents.last?.id)
                                        plan.rebuildLinearDependencies()
                                    }
                                } label: {
                                    Label(agent.name, systemImage: agent.role.icon)
                                }
                            }
                        }
                    }
                    Section("内置角色") {
                    ForEach(AgentRole.allCases) { role in
                        Button {
                            withAnimation(AppAnimation.quick) {
                                let conn = ModelRouter.selectModel(
                                    forRole: role,
                                    connectors: connectors,
                                    activeConnectorID: connectors.first?.id
                                )
                                let node = AgentNode(role: role, connectorID: conn?.id)
                                plan.addAgent(node, after: plan.agents.last?.id)
                                plan.rebuildLinearDependencies()
                            }
                        } label: {
                            Label("添加\(role.title)", systemImage: role.icon)
                        }
                    }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 11))
                        Text("自建Agent")
                            .font(AppFont.captionMedium)
                    }
                    .foregroundStyle(Brand.primary)
                    .padding(.horizontal, AppSpace.md)
                    .padding(.vertical, AppSpace.xs)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                            .fill(Brand.primaryMuted)
                    )
                }
                .menuStyle(.borderlessButton)

                Button {
                    withAnimation(AppAnimation.quick) { showTemplates.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 11))
                        Text("模板")
                            .font(AppFont.captionMedium)
                    }
                    .foregroundStyle(Brand.primary)
                    .padding(.horizontal, AppSpace.md)
                    .padding(.vertical, AppSpace.xs)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                            .fill(Brand.primaryMuted)
                    )
                }
                .buttonStyle(.plain)
            }

            // Templates panel (collapsible)
            if showTemplates {
                templateGrid
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Agent flow (editable)
            agentFlowEditor

            // Action buttons
            HStack(spacing: AppSpace.md) {
                Button(action: onCancel) {
                    Text("取消")
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(TextGrade.secondary)
                        .padding(.horizontal, AppSpace.lg)
                        .padding(.vertical, AppSpace.sm)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                                .fill(SurfaceGrade.elevated)
                        )
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    plan.isEditable = false
                    onExecute()
                } label: {
                    HStack(spacing: AppSpace.xs) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11))
                        Text("开始执行")
                            .font(AppFont.bodyMedium)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, AppSpace.xl)
                    .padding(.vertical, AppSpace.sm)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                            .fill(Brand.primary)
                    )
                }
                .buttonStyle(.plain)
                .disabled(plan.agents.count < 2)
            }
        }
        .padding(AppSpace.lg)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .fill(SurfaceGrade.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(Brand.primary.opacity(0.2), lineWidth: 1)
        )
        .onAppear {
            agentRegistry.refresh(workspaceRoot: workspaceRoot)
        }
    }

    // MARK: - Template Grid

    private var templateGrid: some View {
        VStack(alignment: .leading, spacing: AppSpace.sm) {
            Text("快速选择协作模板")
                .font(AppFont.captionMedium)
                .foregroundStyle(TextGrade.muted)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: AppSpace.sm),
                GridItem(.flexible(), spacing: AppSpace.sm),
            ], spacing: AppSpace.sm) {
                ForEach(PlanTemplate.templates) { template in
                    templateCard(template)
                }
            }
        }
        .padding(AppSpace.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(SurfaceGrade.panel.opacity(0.5))
        )
    }

    private func templateCard(_ template: PlanTemplate) -> some View {
        Button {
            applyTemplate(template)
            withAnimation(AppAnimation.quick) { showTemplates = false }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: AppSpace.sm) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Brand.primary.opacity(0.1))
                            .frame(width: 26, height: 26)
                        Image(systemName: template.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Brand.primary)
                    }
                    Text(template.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TextGrade.primary)
                    Spacer()
                }
                Text(template.description)
                    .font(.system(size: 10))
                    .foregroundStyle(TextGrade.muted)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    ForEach(template.roles, id: \.rawValue) { role in
                        HStack(spacing: 2) {
                            Image(systemName: role.icon)
                                .font(.system(size: 8, weight: .medium))
                            Text(role.title)
                                .font(.system(size: 8, weight: .medium))
                        }
                        .foregroundStyle(roleColor(for: role))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(roleColor(for: role).opacity(0.08)))
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .fill(SurfaceGrade.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .strokeBorder(SurfaceGrade.border.opacity(0.12), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Agent Flow Editor

    private var agentFlowEditor: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            // Agent chain
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(plan.agents.enumerated()), id: \.element.id) { index, agent in
                        editableAgentNode(agent: agent, index: index)

                        if index < plan.agents.count - 1 {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11))
                                .foregroundStyle(TextGrade.ghost)
                                .frame(width: 24)
                        }
                    }

                    // Add agent button
                    addAgentButton
                }
                .padding(.horizontal, AppSpace.xs)
            }

            // Connector assignment row
            if connectors.count > 1 {
                connectorAssignmentRow
            }
        }
    }

    private func roleColor(for role: AgentRole) -> Color {
        switch role {
        case .coder: return Color(hex: "10B981")
        case .reviewer: return Color(hex: "F59E0B")
        case .researcher: return Color(hex: "3B82F6")
        case .tester: return Color(hex: "8B5CF6")
        case .planner: return Color(hex: "06B6D4")
        }
    }

    private func editableAgentNode(agent: AgentNode, index: Int) -> some View {
        let color = roleColor(for: agent.role)

        return VStack(spacing: AppSpace.xs) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [color.opacity(0.25), color.opacity(0.06)],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: 22
                                )
                            )
                            .frame(width: 44, height: 44)
                        Image(systemName: agent.role.icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(color)
                    }

                    Text(agent.role.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TextGrade.primary)

                    // Step number
                    Text("#\(index + 1)")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(TextGrade.ghost)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                        .fill(SurfaceGrade.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                        .strokeBorder(color.opacity(0.2), lineWidth: 1)
                )
                .shadow(color: color.opacity(0.08), radius: 8, y: 3)

                if plan.agents.count > 2 {
                    Button {
                        withAnimation(AppAnimation.spring) {
                            plan.removeAgent(agent.id)
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(TextGrade.muted)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(SurfaceGrade.elevated))
                            .overlay(Circle().strokeBorder(SurfaceGrade.border.opacity(0.3), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                }
            }
        }
    }

    private var addAgentButton: some View {
        Menu {
            ForEach(AgentRole.allCases) { role in
                let alreadyUsed = plan.agents.contains(where: { $0.role == role })
                Button {
                    withAnimation(AppAnimation.spring) {
                        let node = AgentNode(role: role)
                        plan.addAgent(node, after: plan.agents.last?.id)
                        plan.rebuildLinearDependencies()
                    }
                } label: {
                    HStack {
                        Image(systemName: role.icon)
                        Text(role.title)
                        if alreadyUsed {
                            Text("（已存在）").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .strokeBorder(Brand.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .frame(width: 44, height: 44)
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Brand.primary.opacity(0.5))
                }
                Text("添加")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(TextGrade.ghost)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .menuStyle(.borderlessButton)
    }

    private var connectorAssignmentRow: some View {
        VStack(alignment: .leading, spacing: AppSpace.xs) {
            Text("模型分配")
                .font(AppFont.tiny)
                .foregroundStyle(TextGrade.muted)

            HStack(spacing: AppSpace.sm) {
                ForEach(Array(plan.agents.enumerated()), id: \.element.id) { index, agent in
                    Menu {
                        ForEach(connectors) { conn in
                            Button {
                                plan.agents[index].connectorID = conn.id
                            } label: {
                                HStack {
                                    Text(conn.name)
                                    if conn.id == agent.connectorID {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: agent.role.icon)
                                .font(.system(size: 9))
                            Text(connectorName(for: agent.connectorID))
                                .font(AppFont.tiny)
                                .lineLimit(1)
                        }
                        .foregroundStyle(TextGrade.secondary)
                        .padding(.horizontal, AppSpace.sm)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                                .fill(SurfaceGrade.panel)
                        )
                    }
                    .menuStyle(.borderlessButton)
                }
            }
        }
    }

    // MARK: - Helpers

    private func applyTemplate(_ template: PlanTemplate) {
        var agents: [AgentNode] = []
        for role in template.roles {
            let conn = ModelRouter.selectModel(
                forRole: role,
                connectors: connectors,
                activeConnectorID: connectors.first?.id
            )
            agents.append(AgentNode(role: role, connectorID: conn?.id))
        }
        // Build linear dependencies
        for i in 1..<agents.count {
            agents[i].dependsOn = [agents[i - 1].id]
        }
        var handoffs: [AgentHandoff] = []
        for i in 1..<agents.count {
            handoffs.append(AgentHandoff(
                fromAgentID: agents[i - 1].id,
                toAgentID: agents[i].id,
                artifact: ""
            ))
        }
        plan = MultiAgentPlan(
            title: template.roles.map { $0.title }.joined(separator: " → "),
            agents: agents,
            handoffs: handoffs,
            status: .queued,
            isEditable: true
        )
    }

    private func connectorName(for id: UUID?) -> String {
        guard let id else { return "自动" }
        return connectors.first(where: { $0.id == id })?.name ?? "自动"
    }
}

// MARK: - Resume Failed Plan Button

struct ResumePlanButton: View {
    let plan: MultiAgentPlan
    let onResume: () -> Void

    var body: some View {
        if !plan.failedAgents.isEmpty && plan.status == .failed {
            Button(action: onResume) {
                HStack(spacing: AppSpace.sm) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .medium))
                    Text("从失败处继续（\(plan.failedAgents.count)个Agent）")
                        .font(AppFont.captionMedium)
                }
                .foregroundStyle(Semantic.warning)
                .padding(.horizontal, AppSpace.lg)
                .padding(.vertical, AppSpace.sm)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                        .fill(Semantic.warningMuted)
                )
            }
            .buttonStyle(.plain)
        }
    }
}
