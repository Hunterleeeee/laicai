import SwiftUI
import LaicaiNativeDomain
import LaicaiNativeFoundation

// MARK: - Usage Stats Panel

struct UsageStatsPanel: View {
    @EnvironmentObject private var store: AppStore
    @State private var period: StatsPeriod = .week
    @State private var dailyData: [DailyUsageRow] = []
    @State private var modelData: [ModelUsageRow] = []
    @State private var projectData: [ProjectUsageRow] = []
    @State private var totals = UsageTotals()
    @State private var hourlyData: [HourlyUsageRow] = []
    @State private var taskStats: [OutcomeStatsRow] = []
    @State private var toolStats: [ToolStatsRow] = []
    @State private var threadRanking: [ThreadUsageRow] = []
    @State private var intentData: [IntentUsageRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.lg) {
            statsOverview

            Group {
                summaryRow

                dailyChart

                if !hourlyData.isEmpty {
                    hourlyChart
                }

                if !modelData.isEmpty {
                    modelBreakdownSection
                }
            }

            Group {
                if !projectData.isEmpty {
                    projectBreakdownSection
                }

                if !intentData.isEmpty {
                    intentBreakdownSection
                }

                if !threadRanking.isEmpty {
                    threadRankingSection
                }

                if !taskStats.isEmpty {
                    taskStatsSection
                }

                if !toolStats.isEmpty {
                    toolStatsSection
                }

                OrchestrationHealthSection()
            }
        }
        .onAppear { refresh() }
        .onChange(of: period) { _ in refresh() }
    }

    private var statsOverview: some View {
        workbenchHeroCard(
            icon: "chart.bar.xaxis",
            title: "统计",
            subtitle: "\(period.label) · \(totals.requestCount) 次请求 · \(formatTokens(totals.totalTokens)) 总用量",
            tint: Brand.teal
        ) {
            periodPicker
        }
    }

    // MARK: - Period Picker

    private var periodPicker: some View {
        HStack(spacing: 2) {
            ForEach(StatsPeriod.allCases) { p in
                Button {
                    withAnimation(AppAnimation.quick) { period = p }
                } label: {
                    Text(p.label)
                        .font(.system(size: 11, weight: period == p ? .semibold : .regular))
                        .foregroundStyle(period == p ? Brand.teal : TextGrade.muted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                                .fill(period == p ? Brand.teal.opacity(0.11) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                                .strokeBorder(period == p ? Brand.teal.opacity(0.16) : Color.clear, lineWidth: 0.6)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(AppSpace.xs)
        .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(SurfaceGrade.card.opacity(0.58)))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).strokeBorder(SurfaceGrade.hairline.opacity(0.74), lineWidth: 0.6))
    }

    // MARK: - Summary Row

    private var summaryRow: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: AppSpace.sm) {
            summaryCard(
                icon: "arrow.down.left",
                label: "输入",
                value: formatTokens(totals.inputTokens),
                color: Brand.primary
            )
            summaryCard(
                icon: "arrow.up.right",
                label: "输出",
                value: formatTokens(totals.outputTokens),
                color: Brand.purple
            )
            summaryCard(
                icon: "sum",
                label: "总计",
                value: formatTokens(totals.totalTokens),
                color: TextGrade.primary
            )
            summaryCard(
                icon: "dollarsign.circle",
                label: "费用",
                value: formatCost(totals.estimatedCost),
                color: Semantic.warning
            )
            summaryCard(
                icon: "arrow.triangle.2.circlepath",
                label: "请求",
                value: "\(totals.requestCount)",
                color: TextGrade.secondary
            )
            summaryCard(
                icon: "speedometer",
                label: "速度",
                value: totals.avgSpeed > 0 ? String(format: "%.0ft/s", totals.avgSpeed) : "-",
                color: Semantic.success
            )
        }
    }

    private func summaryCard(icon: String, label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8))
                    .foregroundStyle(color.opacity(0.7))
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(TextGrade.muted)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, AppSpace.sm)
        .padding(.vertical, AppSpace.sm - 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(SurfaceGrade.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(color.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Daily Chart

    private var dailyChart: some View {
        VStack(alignment: .leading, spacing: AppSpace.sm) {
            Text("每日用量")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TextGrade.secondary)

            if dailyData.isEmpty {
                Text("暂无数据")
                    .font(.system(size: 11))
                    .foregroundStyle(TextGrade.ghost)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                let maxTotal = dailyData.map(\.totalTokens).max() ?? 1
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(dailyData) { day in
                        VStack(spacing: 2) {
                            // Stacked bar: input (bottom) + output (top)
                            VStack(spacing: 0) {
                                Rectangle()
                                    .fill(Brand.purple.opacity(0.8))
                                    .frame(height: barHeight(day.outputTokens, maxValue: maxTotal))
                                Rectangle()
                                    .fill(Brand.primary.opacity(0.8))
                                    .frame(height: barHeight(day.inputTokens, maxValue: maxTotal))
                            }
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 2))

                            Text(shortDate(day.dateKey))
                                .font(.system(size: 8))
                                .foregroundStyle(TextGrade.ghost)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(height: 100)

                // Legend
                HStack(spacing: AppSpace.md) {
                    legendDot(color: Brand.primary, label: "输入")
                    legendDot(color: Brand.purple, label: "输出")
                }
            }
        }
        .padding(AppSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SurfaceGrade.card.opacity(0.72))
        )
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SurfaceGrade.hairline.opacity(0.70), lineWidth: 0.6))
    }

    // MARK: - Hourly Chart

    private var hourlyChart: some View {
        VStack(alignment: .leading, spacing: AppSpace.sm) {
            Text("今日活跃时段")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TextGrade.secondary)

            let maxTokens = hourlyData.map(\.totalTokens).max() ?? 1
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<24, id: \.self) { hour in
                    let row = hourlyData.first(where: { $0.hour == hour })
                    let tokens = row?.totalTokens ?? 0
                    VStack(spacing: 1) {
                        Rectangle()
                            .fill(tokens > 0 ? Brand.primary.opacity(0.7) : SurfaceGrade.elevated)
                            .frame(height: max(2, CGFloat(tokens) / CGFloat(max(1, maxTokens)) * 40))
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 1))
                        if hour % 6 == 0 {
                            Text("\(hour)")
                                .font(.system(size: 7))
                                .foregroundStyle(TextGrade.ghost)
                        }
                    }
                }
            }
            .frame(height: 55)
        }
        .padding(AppSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SurfaceGrade.card.opacity(0.72))
        )
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SurfaceGrade.hairline.opacity(0.70), lineWidth: 0.6))
    }

    // MARK: - Model Breakdown

    private var modelBreakdownSection: some View {
        VStack(alignment: .leading, spacing: AppSpace.sm) {
            Text("模型用量分布")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TextGrade.secondary)

            ForEach(modelData) { row in
                HStack(spacing: AppSpace.sm) {
                    Text(row.modelName.isEmpty ? "未知" : row.modelName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TextGrade.primary)
                        .lineLimit(1)
                        .frame(maxWidth: 140, alignment: .leading)

                    // Proportion bar
                    let totalAll = modelData.reduce(0) { $0 + $1.totalTokens }
                    let fraction = totalAll > 0 ? CGFloat(row.totalTokens) / CGFloat(totalAll) : 0
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Brand.primary.opacity(0.6))
                            .frame(width: geo.size.width * fraction)
                    }
                    .frame(height: 8)

                    VStack(alignment: .trailing, spacing: 1) {
                        Text(formatTokens(row.totalTokens))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(TextGrade.secondary)
                        Text(formatCost(row.estimatedCost))
                            .font(.system(size: 9))
                            .foregroundStyle(TextGrade.ghost)
                    }
                    .frame(width: 60, alignment: .trailing)

                    Text("\(row.requestCount) 次")
                        .font(.system(size: 9))
                        .foregroundStyle(TextGrade.ghost)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
        .padding(AppSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SurfaceGrade.card.opacity(0.72))
        )
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SurfaceGrade.hairline.opacity(0.70), lineWidth: 0.6))
    }

    // MARK: - Project Breakdown

    private var projectBreakdownSection: some View {
        VStack(alignment: .leading, spacing: AppSpace.sm) {
            Text("项目消耗")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TextGrade.secondary)

            ForEach(projectData) { row in
                HStack(spacing: AppSpace.sm) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Brand.primaryLight)
                    Text(row.projectName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TextGrade.primary)
                        .lineLimit(1)
                    Spacer()
                    Text(formatTokens(row.totalTokens))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TextGrade.secondary)
                    Text("\(row.requestCount) 次")
                        .font(.system(size: 9))
                        .foregroundStyle(TextGrade.ghost)
                }
            }
        }
        .padding(AppSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SurfaceGrade.card.opacity(0.72))
        )
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SurfaceGrade.hairline.opacity(0.70), lineWidth: 0.6))
    }

    // MARK: - Agent Stats

    private var taskStatsSection: some View {
        VStack(alignment: .leading, spacing: AppSpace.sm) {
            Text("会话 完成率")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TextGrade.secondary)

            ForEach(Array(taskStats.enumerated()), id: \.offset) { _, row in
                HStack(spacing: AppSpace.sm) {
                    Text(row.intent.isEmpty ? "通用" : row.intent)
                        .font(.system(size: 11))
                        .foregroundStyle(TextGrade.primary)
                        .frame(maxWidth: 100, alignment: .leading)
                        .lineLimit(1)

                    // Success rate bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(SurfaceGrade.elevated)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(row.completionRate > 0.7 ? Semantic.success : Semantic.warning)
                                .frame(width: geo.size.width * CGFloat(row.completionRate))
                        }
                    }
                    .frame(height: 8)

                    Text(String(format: "%.0f%%", row.completionRate * 100))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(row.completionRate > 0.7 ? Semantic.success : Semantic.warning)
                        .frame(width: 36, alignment: .trailing)

                    Text("\(row.total) 个")
                        .font(.system(size: 9))
                        .foregroundStyle(TextGrade.ghost)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(AppSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SurfaceGrade.card)
        )
    }

    // MARK: - Tool Stats

    private var toolStatsSection: some View {
        VStack(alignment: .leading, spacing: AppSpace.sm) {
            Text("工具稳定性")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TextGrade.secondary)

            ForEach(Array(toolStats.prefix(10).enumerated()), id: \.offset) { _, row in
                HStack(spacing: AppSpace.sm) {
                    Text(row.toolName)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(TextGrade.primary)
                        .lineLimit(1)
                        .frame(maxWidth: 120, alignment: .leading)

                    Spacer()

                    // Success rate
                    HStack(spacing: 3) {
                        Circle()
                            .fill(row.successRate > 0.8 ? Semantic.success : (row.successRate > 0.5 ? Semantic.warning : Semantic.error))
                            .frame(width: 5, height: 5)
                        Text(String(format: "%.0f%%", row.successRate * 100))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(TextGrade.secondary)
                    }

                    Text(String(format: "%.1fs", row.avgDuration))
                        .font(.system(size: 9))
                        .foregroundStyle(TextGrade.ghost)
                        .frame(width: 35, alignment: .trailing)

                    Text("\(row.total) 次")
                        .font(.system(size: 9))
                        .foregroundStyle(TextGrade.ghost)
                        .frame(width: 36, alignment: .trailing)

                    if row.retries > 0 {
                        Text("\(row.retries) 重试")
                            .font(.system(size: 8))
                            .foregroundStyle(Semantic.warning)
                    }
                }
            }
        }
        .padding(AppSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SurfaceGrade.card.opacity(0.72))
        )
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SurfaceGrade.hairline.opacity(0.70), lineWidth: 0.6))
    }

    // MARK: - Intent Breakdown

    private var intentBreakdownSection: some View {
        VStack(alignment: .leading, spacing: AppSpace.sm) {
            Text("模式分布")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TextGrade.secondary)

            let totalAll = intentData.reduce(0) { $0 + $1.totalTokens }
            ForEach(intentData) { row in
                HStack(spacing: AppSpace.sm) {
                    Image(systemName: intentIcon(row.intent))
                        .font(.system(size: 9))
                        .foregroundStyle(intentColor(row.intent))
                        .frame(width: 14)

                    Text(row.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TextGrade.primary)
                        .frame(width: 40, alignment: .leading)

                    GeometryReader { geo in
                        let fraction = totalAll > 0 ? CGFloat(row.totalTokens) / CGFloat(totalAll) : 0
                        RoundedRectangle(cornerRadius: 2)
                            .fill(intentColor(row.intent).opacity(0.6))
                            .frame(width: geo.size.width * fraction)
                    }
                    .frame(height: 8)

                    Text(formatTokens(row.totalTokens))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TextGrade.secondary)
                        .frame(width: 50, alignment: .trailing)

                    Text(String(format: "%.1fs", row.avgDuration))
                        .font(.system(size: 9))
                        .foregroundStyle(TextGrade.ghost)
                        .frame(width: 35, alignment: .trailing)

                    Text("\(row.requestCount)次")
                        .font(.system(size: 9))
                        .foregroundStyle(TextGrade.ghost)
                        .frame(width: 32, alignment: .trailing)
                }
            }
        }
        .padding(AppSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SurfaceGrade.card)
        )
    }

    private func intentIcon(_ intent: String) -> String {
        switch intent {
        case "chat": return "bubble.left"
        case "task": return "hammer"
        case "research": return "magnifyingglass"
        default: return "ellipsis"
        }
    }

    private func intentColor(_ intent: String) -> Color {
        switch intent {
        case "chat": return Brand.primary
        case "task": return Brand.purple
        case "research": return Brand.teal
        default: return TextGrade.muted
        }
    }

    // MARK: - Agent Ranking

    private var threadRankingSection: some View {
        VStack(alignment: .leading, spacing: AppSpace.sm) {
            Text("会话 消耗排行")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TextGrade.secondary)

            ForEach(Array(threadRanking.enumerated()), id: \.element.id) { idx, row in
                HStack(spacing: AppSpace.sm) {
                    // Rank number
                    Text("\(idx + 1)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(idx < 3 ? Brand.primary : TextGrade.ghost)
                        .frame(width: 16)

                    // Thread title (lookup from store)
                    Text(threadTitle(for: row.threadID))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TextGrade.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Token count
                    Text(formatTokens(row.totalTokens))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TextGrade.secondary)

                    // Cost
                    Text(formatCost(row.estimatedCost))
                        .font(.system(size: 9))
                        .foregroundStyle(Semantic.warning)

                    // Avg duration
                    Text(String(format: "%.1fs", row.avgDuration))
                        .font(.system(size: 9))
                        .foregroundStyle(TextGrade.ghost)
                        .frame(width: 35, alignment: .trailing)
                }
            }
        }
        .padding(AppSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SurfaceGrade.card)
        )
    }

    private func threadTitle(for threadID: String) -> String {
        guard let uuid = UUID(uuidString: threadID) else { return String(threadID.prefix(8)) }
        if let thread = store.state.threads.first(where: { $0.id == uuid }) {
            return thread.title.isEmpty ? "新会话" : thread.title
        }
        return String(threadID.prefix(8)) + "…"
    }

    // MARK: - Helpers

    private func refresh() {
        let days = period.days
        dailyData = UsageTracker.shared.dailyUsage(days: days)
        modelData = UsageTracker.shared.modelBreakdown(days: days)
        projectData = UsageTracker.shared.projectBreakdown(days: days)
        totals = UsageTracker.shared.totals(days: days)
        hourlyData = UsageTracker.shared.hourlyToday()
        taskStats = TaskOutcomeRecorder.shared.stats(days: days)
        toolStats = TaskOutcomeRecorder.shared.toolStats(days: days)
        threadRanking = UsageTracker.shared.topThreads(days: days, limit: 8)
        intentData = UsageTracker.shared.intentBreakdown(days: days)
    }

    private func barHeight(_ value: Int, maxValue: Int) -> CGFloat {
        guard maxValue > 0 else { return 2 }
        return Swift.max(2, CGFloat(value) / CGFloat(maxValue) * 80)
    }

    private func shortDate(_ dateKey: String) -> String {
        // "2026-05-10" → "5/10"
        let parts = dateKey.split(separator: "-")
        guard parts.count == 3 else { return dateKey }
        let month = Int(parts[1]) ?? 0
        let day = Int(parts[2]) ?? 0
        return "\(month)/\(day)"
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 9)).foregroundStyle(TextGrade.ghost)
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return "\(count)"
    }

    private func formatCost(_ cost: Double) -> String {
        if cost < 0.001 { return "$0.00" }
        if cost < 0.01 { return "< $0.01" }
        return String(format: "$%.2f", cost)
    }
}

// MARK: - Stats Period

// MARK: - Orchestration Health Section

struct OrchestrationHealthSection: View {
    @EnvironmentObject private var store: AppStore

    private var currentTask: AgentTask? {
        guard let id = store.state.selectedThreadID,
              let thread = store.state.threads.first(where: { $0.id == id }),
              thread.isExecution else { return nil }
        return AgentTask(thread: thread)
    }

    var body: some View {
        if let task = currentTask {
            let stats = computeStats(task)
            contextSectionCard(title: "当前会话状态", tint: Semantic.warning) {
                VStack(alignment: .leading, spacing: AppSpace.sm) {
                    Group {
                        statRow(icon: "wrench.and.screwdriver", label: "工具调用", value: "\(stats.toolCalls) 次", color: Brand.primary)
                        statRow(icon: "checkmark.circle", label: "成功", value: "\(stats.toolSuccesses) 次", color: Semantic.success)
                        statRow(icon: "xmark.circle", label: "失败", value: "\(stats.toolFailures) 次", color: stats.toolFailures > 0 ? Semantic.error : TextGrade.ghost)
                        statRow(icon: "arrow.triangle.2.circlepath", label: "自动恢复", value: "\(stats.recoveries) 次", color: stats.recoveries > 0 ? Semantic.warning : TextGrade.ghost)
                        statRow(icon: "checkmark.seal", label: "恢复成功", value: "\(stats.recoverySuccesses) 次", color: stats.recoverySuccesses > 0 ? Semantic.success : TextGrade.ghost)
                    }
                    Group {
                        Divider().opacity(0.3)
                        statRow(icon: "doc.text", label: "消息数", value: "\(stats.messageCount)", color: Brand.primary)
                        statRow(icon: "arrow.down.right.and.arrow.up.left", label: "上下文整理", value: stats.compressionActive ? "已启用" : "未触发", color: stats.compressionActive ? Semantic.warning : TextGrade.ghost)
                        statRow(icon: "cpu", label: "模型适配", value: stats.modelAdaptation, color: Brand.primary)
                    }
                    if stats.circuitBroken > 0 {
                        Divider().opacity(0.3)
                        statRow(icon: "bolt.trianglebadge.exclamationmark", label: "暂停重试", value: "\(stats.circuitBroken) 项", color: Semantic.error)
                    }
                    if stats.toolCalls > 0 {
                        successRateBar(stats: stats)
                    }
                }
            }
        }
    }

    private func statRow(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: AppSpace.sm) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 14)
            Text(label)
                .font(AppFont.tiny)
                .foregroundStyle(TextGrade.muted)
            Spacer()
            Text(value)
                .font(AppFont.codeSmall)
                .foregroundStyle(color == TextGrade.ghost ? TextGrade.ghost : TextGrade.secondary)
                .lineLimit(1)
        }
    }

    private func successRateBar(stats: OrcStats) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider().opacity(0.3)
            Text("成功率")
                .font(AppFont.tiny)
                .foregroundStyle(TextGrade.muted)
            GeometryReader { geo in
                let rate = Double(stats.toolSuccesses) / Double(max(1, stats.toolCalls))
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(SurfaceGrade.sunken.opacity(0.4))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(rate > 0.8 ? Semantic.success : (rate > 0.5 ? Semantic.warning : Semantic.error))
                        .frame(width: geo.size.width * CGFloat(rate), height: 6)
                }
            }
            .frame(height: 6)
            Text("\(Int(Double(stats.toolSuccesses) / Double(max(1, stats.toolCalls)) * 100))%")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(TextGrade.ghost)
        }
    }

    private struct OrcStats {
        var toolCalls = 0
        var toolSuccesses = 0
        var toolFailures = 0
        var recoveries = 0
        var recoverySuccesses = 0
        var circuitBroken = 0
        var messageCount = 0
        var compressionActive = false
        var modelAdaptation = "标准"
    }

    private func computeStats(_ task: AgentTask) -> OrcStats {
        var s = OrcStats()
        for step in task.steps {
            let isRecovery = (step.toolCallId ?? "").hasPrefix("call_recovery_") || step.text.hasPrefix("自动恢复")
            if step.kind == .toolCall && !isRecovery {
                s.toolCalls += 1
            }
            if step.kind == .toolResult && !isRecovery {
                if step.isFailure { s.toolFailures += 1 } else { s.toolSuccesses += 1 }
            }
            if isRecovery && step.kind == .toolCall {
                s.recoveries += 1
            }
            if isRecovery && step.kind == .toolResult && !step.isFailure {
                s.recoverySuccesses += 1
            }
        }

        // Circuit broken: count unique tool+target combos that failed 3+ times
        let failedSigs = task.steps.filter { $0.kind == .toolResult && $0.isFailure }.map {
            "\($0.toolName ?? ""):\(($0.toolParams?["path"] ?? $0.toolParams?["query"] ?? "").prefix(40))"
        }
        let sigCounts = Dictionary(grouping: failedSigs, by: { $0 }).mapValues(\.count)
        s.circuitBroken = sigCounts.filter { $0.value >= 3 }.count

        // Message count estimate (toolCalls * 2 for call+result + user inputs + system messages)
        s.messageCount = task.steps.count

        // Compression heuristic: if messages > 30, compression likely active
        let totalContentLength = task.steps.reduce(0) { $0 + $1.text.count }
        s.compressionActive = s.messageCount > 30 || totalContentLength > 50_000

        // Model adaptation
        if let connector = store.state.activeConnector {
            let model = connector.modelName.lowercased()
            if model.contains("ollama") || model.contains("local") {
                s.modelAdaptation = "本地精简"
            } else if model.contains("deepseek") {
                s.modelAdaptation = "DeepSeek 优化"
            } else if model.contains("qwen") {
                s.modelAdaptation = "Qwen 适配"
            }
        }

        return s
    }
}

private enum StatsPeriod: String, CaseIterable, Identifiable {
    case today
    case week
    case month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return "今天"
        case .week: return "7 天"
        case .month: return "30 天"
        }
    }

    var days: Int {
        switch self {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        }
    }
}
