import SwiftUI
import LaicaiNativeDomain
import LaicaiNativeFoundation

struct WorkbenchView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var isVisible: Bool

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            panelContent
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(WorkbenchTabItem.allCases) { item in
                        WorkbenchTabButton(
                            item: item,
                            isSelected: store.state.workbenchTab == item.tab,
                            badge: badgeCount(for: item),
                            action: { store.selectWorkbenchTab(item.tab) }
                        )
                    }
                }
                .padding(.horizontal, AppSpace.sm)
            }

            Spacer(minLength: 0)

            IconButton(icon: "chevron.right.2", tooltip: "收起面板") {
                isVisible = false
            }
            .padding(.trailing, AppSpace.sm)
        }
        .padding(.vertical, AppSpace.xs + 2)
        .overlay(alignment: .bottom) { Rectangle().fill(SurfaceGrade.divider).frame(height: 1) }
    }

    private func badgeCount(for item: WorkbenchTabItem) -> Int {
        switch item {
        case .context: return store.state.connectors.count
        case .tools: return store.state.toolActivities.count
        case .workflows:
            let wfs = WorkflowLibrary.available(workspaceRoot: store.state.settings.workspacePath)
            return wfs.count
        case .skills: return SkillRegistry.shared.skills.count
        case .agents: return AgentRegistry.shared.agents.count
        case .logs: return AuditLog.shared.recentEntries.count
        default: return 0
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpace.lg) {
                switch store.state.workbenchTab {
                case .context: ConnectorsPanel()
                case .tools: ActivityPanel()
                case .workflows: WorkflowsPanel()
                case .skills: SkillHubView()
                case .agents: AgentsPanel()
                case .wiki: WikiPanel()
                case .report: ReportPanel()
                case .stats: UsageStatsPanel()
                case .logs: DiagnosticsPanel()
                }
            }
            .padding(AppSpace.md)
        }
    }
}

// MARK: - Tab Item

enum WorkbenchTabItem: String, CaseIterable, Identifiable {
    case context, tools, workflows, skills, agents, wiki, report, stats, logs

    var id: String { rawValue }

    var tab: WorkbenchTab {
        switch self {
        case .context: return .context
        case .tools: return .tools
        case .workflows: return .workflows
        case .skills: return .skills
        case .agents: return .agents
        case .wiki: return .wiki
        case .report: return .report
        case .stats: return .stats
        case .logs: return .logs
        }
    }

    var title: String {
        switch self {
        case .context: return "连接"
        case .tools: return "活动"
        case .workflows: return "工作流"
        case .skills: return "技能"
        case .agents: return "Agent"
        case .wiki: return "Wiki"
        case .report: return "报告"
        case .stats: return "统计"
        case .logs: return "日志"
        }
    }

    var icon: String {
        switch self {
        case .context: return "link"
        case .tools: return "bolt.horizontal"
        case .workflows: return "arrow.triangle.branch"
        case .skills: return "star"
        case .agents: return "person.3"
        case .wiki: return "book.closed"
        case .report: return "chart.bar.doc.horizontal"
        case .stats: return "chart.bar.xaxis"
        case .logs: return "terminal"
        }
    }
}

struct WorkbenchTabButton: View {
    let item: WorkbenchTabItem
    let isSelected: Bool
    var badge: Int = 0
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: item.icon)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                Text(item.title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(isSelected ? Brand.primary : TextGrade.ghost)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(isSelected ? Brand.primary.opacity(0.15) : SurfaceGrade.elevated.opacity(0.6))
                        )
                }
            }
            .foregroundStyle(isSelected ? Brand.primary : (isHovering ? TextGrade.secondary : TextGrade.muted))
            .padding(.horizontal, AppSpace.sm)
            .padding(.vertical, AppSpace.xs + 2)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                    .fill(isSelected ? Brand.primary.opacity(0.10) : (isHovering ? SurfaceGrade.hover : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                    .strokeBorder(isSelected ? Brand.primary.opacity(0.2) : Color.clear, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(item.title)
        .onHover { h in withAnimation(AppAnimation.quick) { isHovering = h } }
    }
}

// Panel implementations → WorkbenchPanels.swift
