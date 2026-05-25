import SwiftUI
import LaicaiNativeDomain
import LaicaiNativeFoundation

struct WorkbenchView: View {
    @EnvironmentObject private var store: AppStore

    private var primaryItems: [WorkbenchTabItem] { [.tools, .connectors, .agents] }
    private var secondaryItems: [WorkbenchTabItem] { [.workflows, .skills, .schedules, .wiki, .report, .stats, .logs] }

    var body: some View {
        VStack(spacing: 0) {
            drawerHeader
            primarySwitch
            panelContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            ZStack {
                SurfaceGrade.panel
                SurfaceGrade.base.opacity(0.36)
            }
        )
    }

    // MARK: - Header

    private var drawerHeader: some View {
        HStack(alignment: .center, spacing: AppSpace.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .fill(activeHeaderTint.opacity(0.12))
                    .frame(width: 30, height: 30)
                Image(systemName: activeHeaderIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(activeHeaderTint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(activeTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TextGrade.primary)
                Text(activeSubtitle)
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Menu {
                Button {
                    store.selectWorkbenchTab(.tools)
                } label: {
                    Label("会话检查器", systemImage: "sidebar.trailing")
                }
                Button {
                    store.selectWorkbenchTab(.context)
                } label: {
                    Label("模型连接", systemImage: "cpu")
                }
                Button {
                    store.selectWorkbenchTab(.agents)
                } label: {
                    Label("会话编排", systemImage: "person.3")
                }
                Divider()
                ForEach(secondaryItems) { item in
                    Button {
                        store.selectWorkbenchTab(item.tab)
                    } label: {
                        Label(item.title, systemImage: item.icon)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TextGrade.muted)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("更多面板")
        }
        .padding(.horizontal, AppSpace.md)
        .padding(.top, AppSpace.sm)
        .padding(.bottom, AppSpace.sm)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SurfaceGrade.divider.opacity(0.58)).frame(height: 0.5)
        }
    }

    private var primarySwitch: some View {
        VStack(spacing: AppSpace.xs) {
            HStack(spacing: AppSpace.xs) {
                ForEach(primaryItems) { item in
                    WorkbenchSegmentButton(
                        title: item.shortTitle,
                        icon: item.icon,
                        isSelected: store.state.workbenchTab == item.tab
                    ) {
                        store.selectWorkbenchTab(item.tab)
                    }
                }
            }
        }
        .padding(AppSpace.xs)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(SurfaceGrade.card.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(SurfaceGrade.hairline, lineWidth: 0.6)
        )
        .padding(.horizontal, AppSpace.md)
        .padding(.top, AppSpace.xs)
        .padding(.bottom, AppSpace.xs)
    }

    private var activeTitle: String {
        switch store.state.workbenchTab {
        case .context: return "模型连接"
        case .tools: return "会话检查器"
        case .agents: return "会话编排"
        default: return store.state.workbenchTab.title
        }
    }

    private var activeSubtitle: String {
        switch store.state.workbenchTab {
        case .context: return headerModelTitle
        case .tools: return selectedThreadTitle
        case .schedules: return "定期触发巡检、复盘和报告"
        case .agents: return "规划、编码、测试和审查"
        default: return "右侧工具面板"
        }
    }

    private var activeHeaderTint: Color {
        switch store.state.workbenchTab {
        case .context: return Brand.teal
        case .schedules: return Semantic.warning
        case .agents: return Brand.purple
        default: return Brand.primary
        }
    }

    private var activeHeaderIcon: String {
        switch store.state.workbenchTab {
        case .context: return "cpu"
        case .schedules: return "alarm"
        case .agents: return "person.3.sequence"
        default: return "sidebar.trailing"
        }
    }

    private var selectedThreadTitle: String {
        guard let thread = store.state.selectedThread else { return "选择会话后显示状态、计划和证据" }
        let title = TextHelper.compactTitle(thread.title)
        return title.isEmpty ? "新会话" : title
    }

    private var headerModelTitle: String {
        guard let connector = store.state.activeConnector else { return "模型未连接" }
        return connector.modelName.isEmpty ? connector.name : connector.modelName
    }

    @ViewBuilder
    private var panelContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpace.md) {
                switch store.state.workbenchTab {
                case .tools: ActivityPanel()
                case .context: ConnectorsPanel()
                case .workflows: WorkflowsPanel()
                case .skills: SkillHubView()
                case .schedules: SchedulesPanel()
                case .agents: AgentsPanel()
                case .wiki: WikiPanel()
                case .report: ReportPanel()
                case .stats: UsageStatsPanel()
                case .logs: DiagnosticsPanel()
                }
            }
            .padding(.horizontal, AppSpace.md)
            .padding(.vertical, AppSpace.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Tab Item

enum WorkbenchTabItem: String, CaseIterable, Identifiable {
    case connectors, tools, workflows, skills, schedules, agents, wiki, report, stats, logs

    var id: String { rawValue }

    var tab: WorkbenchTab {
        switch self {
        case .connectors: return .context
        case .tools: return .tools
        case .workflows: return .workflows
        case .skills: return .skills
        case .schedules: return .schedules
        case .agents: return .agents
        case .wiki: return .wiki
        case .report: return .report
        case .stats: return .stats
        case .logs: return .logs
        }
    }

    var title: String {
        switch self {
        case .connectors: return "模型连接"
        case .tools: return "活动"
        case .workflows: return "流程"
        case .skills: return "技能"
        case .schedules: return "定时会话"
        case .agents: return "会话"
        case .wiki: return "Wiki"
        case .report: return "报告"
        case .stats: return "统计"
        case .logs: return "诊断"
        }
    }

    var shortTitle: String {
        switch self {
        case .connectors: return "模型"
        case .tools: return "检查"
        case .agents: return "编排"
        default: return title
        }
    }

    var icon: String {
        switch self {
        case .connectors: return "cpu"
        case .tools: return "waveform.path.ecg"
        case .workflows: return "arrow.triangle.branch"
        case .skills: return "sparkles"
        case .schedules: return "alarm"
        case .agents: return "person.3"
        case .wiki: return "book.closed"
        case .report: return "chart.bar.doc.horizontal"
        case .stats: return "chart.bar.xaxis"
        case .logs: return "terminal"
        }
    }
}

private struct WorkbenchSegmentButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpace.xs) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(AppFont.captionMedium)
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? TextGrade.primary : (isHovering ? TextGrade.secondary : TextGrade.muted))
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                    .fill(isSelected ? SurfaceGrade.selected : (isHovering ? SurfaceGrade.hover : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                    .strokeBorder(isSelected ? SurfaceGrade.hairline : Color.clear, lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(AppAnimation.quick) { isHovering = hovering } }
    }
}

struct InspectorTabButton: View {
    let item: WorkbenchTabItem
    let isSelected: Bool
    var badge: Int = 0
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: item.icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(item.title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                if badge > 0 {
                    Text(shortBadge(badge))
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(isSelected ? Brand.primaryDark : TextGrade.ghost)
                }
            }
            .foregroundStyle(isSelected ? Brand.primaryDark : (isHovering ? TextGrade.secondary : TextGrade.muted))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 30)
            .padding(.horizontal, AppSpace.sm)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                    .fill(isSelected ? Brand.primary.opacity(0.13) : (isHovering ? SurfaceGrade.hover : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                    .strokeBorder(isSelected ? Brand.primary.opacity(0.24) : SurfaceGrade.hairline.opacity(0.0), lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
        .help(item.title)
        .onHover { h in withAnimation(AppAnimation.quick) { isHovering = h } }
    }

    private func shortBadge(_ count: Int) -> String {
        count > 99 ? "99+" : "\(count)"
    }
}

// Panel implementations -> WorkbenchPanels.swift
