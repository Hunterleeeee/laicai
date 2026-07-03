import SwiftUI
import LaicaiNativeDomain
import LaicaiNativeFoundation

// MARK: - Diagnostics Panel

struct DiagnosticsPanel: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var auditLog = AuditLog.shared
    @State private var confirmClearAudit = false
    @State private var copiedDiagnostics = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.large) {
            diagnosticsOverview

            // Stats grid
            HStack(spacing: AppSpace.small) {
                diagStatBadge(
                    icon: "rectangle.stack",
                    label: "线程",
                    value: "\(store.state.threads.count)",
                    color: Brand.primary
                )
                diagStatBadge(
                    icon: "waveform.path.ecg",
                    label: "运行",
                    value: "\(store.state.threads.filter { $0.executionState == .running || $0.executionState == .planning }.count)",
                    color: Brand.purple
                )
                diagStatBadge(
                    icon: "bolt.horizontal",
                    label: "活动",
                    value: "\(store.state.toolActivities.count)",
                    color: Brand.teal
                )
                diagStatBadge(
                    icon: "shield",
                    label: "审计",
                    value: "\(auditLog.recentEntries.count)",
                    color: Semantic.warning
                )
            }

            // Environment info
            contextSectionCard(title: "本机环境", tint: Brand.teal) {
                VStack(spacing: 0) {
                    diagRow("工作区", URL(fileURLWithPath: store.state.settings.workspacePath).lastPathComponent, color: TextGrade.secondary)
                    Divider().opacity(0.3)
                    diagRow("上下文", store.state.settings.contextMode.rawValue, color: TextGrade.secondary)
                    Divider().opacity(0.3)
                    diagRow("系统", "\(ProcessInfo.processInfo.operatingSystemVersionString)", color: TextGrade.secondary)
                    Divider().opacity(0.3)
                    diagRow("内存", formatMemory(), color: TextGrade.secondary)
                }
            }

            // Audit log
            if auditLog.recentEntries.isEmpty {
                workbenchEmptyState(icon: "checkmark.shield", title: "暂无记录", hint: "本机操作会在这里留下简要记录")
            } else {
                VStack(alignment: .leading, spacing: AppSpace.small) {
                    HStack {
                        workbenchSectionHeader(title: "最近记录", count: auditLog.recentEntries.count)
                        Button {
                            confirmClearAudit = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 9))
                                .foregroundStyle(Semantic.error.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        .help("清空记录")
                    }

                    VStack(spacing: AppSpace.extraSmall) {
                        ForEach(auditLog.recentEntries.prefix(15)) { entry in
                            AuditEntryRow(entry: entry)
                        }
                    }
                }
            }

            if store.state.settings.showDebugPanels && !store.state.toolActivities.isEmpty {
                HStack {
                    Text("最近活动")
                        .font(AppFont.captionMedium)
                        .foregroundStyle(TextGrade.secondary)
                    Spacer()
                }

                VStack(spacing: AppSpace.xxs) {
                    ForEach(store.state.toolActivities.prefix(10)) { activity in
                        HStack {
                            Image(systemName: activity.isFailure ? "xmark.circle" : "checkmark.circle")
                                .font(.system(size: 8))
                                .foregroundStyle(activity.isFailure ? Semantic.error : Semantic.success)
                            Text(activity.name)
                                .font(AppFont.codeSmall)
                                .foregroundStyle(TextGrade.primary)
                                .lineLimit(1)
                            Spacer()
                            Text(activity.isFailure ? "失败" : "成功")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(activity.isFailure ? Semantic.error : Semantic.success)
                        }
                    }
                }
            }
        }
        .alert("清空审计记录", isPresented: $confirmClearAudit) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                auditLog.clear()
            }
        } message: {
            Text("这会删除本机当前保存的审计记录。")
        }
    }

    private var diagnosticsOverview: some View {
        workbenchHeroCard(
            icon: store.hasRunningGenerationTasks ? "waveform.path.ecg" : "checkmark.shield.fill",
            title: "诊断",
            subtitle: store.hasRunningGenerationTasks ? "后台会话运行中" : "运行正常 · 最近 \(auditLog.recentEntries.count) 条记录",
            tint: store.hasRunningGenerationTasks ? Brand.teal : Semantic.success
        ) {
            VStack(spacing: AppSpace.small) {
                diagRow("状态", store.hasRunningGenerationTasks ? "生成中" : "空闲",
                        color: store.hasRunningGenerationTasks ? Semantic.toolRunning : Semantic.success)
                Divider().opacity(0.3)
                diagRow("模型", store.state.activeConnector?.modelName ?? "未配置",
                        color: store.state.activeConnector != nil ? TextGrade.primary : Semantic.warning)
                Divider().opacity(0.3)
                diagRow("端点", store.state.activeConnector?.endpoint ?? "—", color: TextGrade.secondary)

                Button {
                    copyDiagnostics()
                } label: {
                    Label(copiedDiagnostics ? "已复制" : "复制信息", systemImage: copiedDiagnostics ? "checkmark" : "doc.on.doc")
                        .font(AppFont.captionMedium)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(copiedDiagnostics ? Semantic.success : Brand.primary)
                .padding(.vertical, AppSpace.small)
                .background(RoundedRectangle(cornerRadius: AppRadius.medium).fill(SurfaceGrade.card.opacity(0.62)))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.medium).strokeBorder(SurfaceGrade.hairline.opacity(0.8), lineWidth: 0.6))
                .help("复制当前信息到剪贴板")
            }
        }
    }

    private func diagRow(_ label: String, _ value: String, color: Color = TextGrade.primary) -> some View {
        HStack {
            Text(label)
                .font(AppFont.caption)
                .foregroundStyle(TextGrade.muted)
            Spacer()
            Text(value)
                .font(AppFont.codeSmall)
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
    }

    private func diagStatBadge(icon: String, label: String, value: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(TextGrade.primary)
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(TextGrade.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpace.small)
        .background(RoundedRectangle(cornerRadius: AppRadius.small).fill(color.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.small).strokeBorder(color.opacity(0.12), lineWidth: 0.5))
    }

    private func formatMemory() -> String {
        let mem = ProcessInfo.processInfo.physicalMemory
        let used = mach_task_self_
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(used, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let usedMB = Double(info.resident_size) / 1_048_576
            let totalGB = Double(mem) / 1_073_741_824
            return "\(String(format: "%.0f", usedMB)) MB / \(String(format: "%.0f", totalGB)) GB"
        }
        return "\(String(format: "%.0f", Double(mem) / 1_073_741_824)) GB"
    }

    private func copyDiagnostics() {
        let conn = store.state.activeConnector
        let lines = [
            "来财诊断信息",
            "==============",
            "状态: \(store.hasRunningGenerationTasks ? "生成中" : "空闲")",
            "模型: \(conn?.modelName ?? "未配置")",
            "端点: \(conn?.endpoint ?? "—")",
            "工作区: \(store.state.settings.workspacePath)",
            "上下文模式: \(store.state.settings.contextMode.rawValue)",
            "会话: \(store.state.threads.count)",
            "运行中会话: \(store.state.threads.filter { $0.executionState == .running || $0.executionState == .planning }.count)",
            "工具活动: \(store.state.toolActivities.count)",
            "审计: \(auditLog.recentEntries.count)",
            "内存: \(formatMemory())",
            "系统: \(ProcessInfo.processInfo.operatingSystemVersionString)"
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copiedDiagnostics = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copiedDiagnostics = false
        }
    }
}

private struct AuditEntryRow: View {
    let entry: AuditEntry
    @State private var isExpanded = false

    private var toolIcon: String {
        switch entry.tool {
        case "file.write", "file.edit": return "doc.badge.arrow.up"
        case "file.read": return "doc.text"
        case "file.rollback": return "arrow.uturn.backward"
        case "code.search": return "magnifyingglass"
        case "shell.exec": return "terminal"
        case "workspace.index": return "folder.badge.gearshape"
        case "git", "git.reset": return "arrow.triangle.branch"
        case "web.search": return "globe"
        case "web.fetch": return "globe.badge.chevron.backward"
        case "wiki.build": return "book.closed"
        case "image.generate": return "photo.badge.plus"
        case "batch.apply": return "doc.on.doc"
        case "batch.rollback": return "arrow.uturn.backward.circle"
        default: return "wrench.and.screwdriver"
        }
    }

    private var summaryText: String {
        // Build a concise one-line summary from available fields
        let toolDisplay = displayToolName(entry.tool)
        let inputShort = shortInput
        if !inputShort.isEmpty {
            return "\(toolDisplay)：\(inputShort)"
        }
        if !entry.output.isEmpty {
            return "\(toolDisplay)：\(String(entry.output.prefix(40)))"
        }
        return toolDisplay
    }

    private var shortInput: String {
        let trimmedInput = entry.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return "" }
        // For file paths, show just the filename
        if trimmedInput.contains("/") {
            return URL(fileURLWithPath: trimmedInput).lastPathComponent
        }
        return String(trimmedInput.prefix(40))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(
                action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } },
                label: {
                    HStack(alignment: .center, spacing: AppSpace.small) {
                        // Status + tool icon
                        ZStack {
                        Circle()
                            .fill(entry.success ? Semantic.success.opacity(0.12) : Semantic.error.opacity(0.12))
                            .frame(width: 22, height: 22)
                        Image(systemName: toolIcon)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(entry.success ? Semantic.success : Semantic.error)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(summaryText)
                            .font(AppFont.captionMedium)
                            .foregroundStyle(TextGrade.primary)
                            .lineLimit(1)

                        Text(RelativeTimeFormatter.string(for: entry.timestamp))
                            .font(AppFont.tiny)
                            .foregroundStyle(TextGrade.ghost)
                    }

                    Spacer(minLength: 0)

                    if hasDetails {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(TextGrade.ghost)
                        }
                    }
                }
            )
            .buttonStyle(.plain)

            if isExpanded && hasDetails {
                VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
                    if !entry.input.isEmpty {
                        auditDetailRow("输入", entry.input)
                    }
                    if !entry.output.isEmpty {
                        auditDetailRow("结果", entry.output)
                    }
                    if !entry.action.isEmpty && entry.action != "tool_call" {
                        auditDetailRow("动作", entry.action)
                    }
                }
                .padding(.leading, 34)
                .padding(.top, AppSpace.extraSmall)
            }
        }
        .padding(AppSpace.small)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(entry.success ? SurfaceGrade.card.opacity(0.72) : Semantic.errorMuted.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(entry.success ? SurfaceGrade.divider : Semantic.error.opacity(0.18), lineWidth: 0.75)
        )
    }

    private var hasDetails: Bool {
        !entry.input.isEmpty || !entry.output.isEmpty || (entry.action != "tool_call" && !entry.action.isEmpty)
    }

    private func auditDetailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: AppSpace.extraSmall) {
            Text(label)
                .font(AppFont.tiny)
                .foregroundStyle(TextGrade.ghost)
                .frame(width: 28, alignment: .trailing)
            Text(value)
                .font(AppFont.codeSmall)
                .foregroundStyle(TextGrade.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    private static let toolDisplayNames: [String: String] = [
        "file.write": "文件写入",
        "file.edit": "文件编辑",
        "file.read": "文件读取",
        "file.rollback": "文件回滚",
        "code.search": "项目搜索",
        "shell.exec": "命令执行",
        "workspace.index": "项目索引",
        "git": "Git 操作",
        "git.reset": "Git 回滚",
        "web.search": "网页搜索",
        "web.fetch": "网页读取",
        "wiki.build": "知识页生成",
        "image.generate": "图片生成",
        "batch.apply": "批量写入",
        "batch.rollback": "批量回滚"
    ]

    private func displayToolName(_ name: String) -> String {
        Self.toolDisplayNames[name] ?? (name.isEmpty ? "操作" : name)
    }
}

// MARK: - Resources Panel

struct ResourcesPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.medium) {
            Text("资源")
                .font(AppFont.subheadline)
                .foregroundStyle(TextGrade.primary)

            VStack(spacing: AppSpace.small) {
                Image(systemName: "folder")
                    .font(.system(size: 32, weight: .ultraLight))
                    .foregroundStyle(TextGrade.ghost)
                Text("暂无资源")
                    .font(AppFont.caption)
                    .foregroundStyle(TextGrade.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpace.extraLarge)
        }
    }
}

// MARK: - Session Cost Card

struct SessionCostCard: View {
    let steps: [TaskStep]

    var body: some View {
        let stats = aggregateMetrics()
        if stats.totalInput > 0 || stats.totalOutput > 0 {
                contextSectionCard(title: "会话消耗") {
                VStack(alignment: .leading, spacing: AppSpace.small) {
                    HStack(spacing: AppSpace.large) {
                        costMetric(icon: "arrow.down.left", label: "输入", value: formatTokens(stats.totalInput), color: Brand.primary)
                        costMetric(icon: "arrow.up.right", label: "输出", value: formatTokens(stats.totalOutput), color: Brand.purple)
                    }

                    Divider().opacity(0.3)

                    HStack(spacing: AppSpace.large) {
                        costMetric(icon: "sum", label: "总计", value: formatTokens(stats.totalInput + stats.totalOutput), color: TextGrade.primary)
                        costMetric(icon: "dollarsign.circle", label: "预估", value: formatCost(stats.estimatedCost), color: Semantic.warning)
                    }

                    if stats.requestCount > 1 {
                        HStack(spacing: AppSpace.large) {
                            costMetric(icon: "arrow.triangle.2.circlepath", label: "请求", value: "\(stats.requestCount) 次", color: TextGrade.secondary)
                            if stats.avgSpeed > 0 {
                                costMetric(icon: "speedometer", label: "均速", value: "\(String(format: "%.0f", stats.avgSpeed)) t/s", color: TextGrade.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private struct AggregatedStats {
        var totalInput: Int = 0
        var totalOutput: Int = 0
        var requestCount: Int = 0
        var totalDuration: TimeInterval = 0
        var avgSpeed: Double = 0
        var estimatedCost: Double = 0
    }

    private func aggregateMetrics() -> AggregatedStats {
        var stats = AggregatedStats()

        for step in steps {
            if let metrics = step.metrics {
                stats.totalInput += metrics.inputTokens ?? 0
                stats.totalOutput += metrics.outputTokens ?? 0
                stats.totalDuration += metrics.totalDuration
                stats.requestCount += 1
            }
        }

        // Calculate averages
        if stats.totalDuration > 0 {
            stats.avgSpeed = Double(stats.totalOutput) / stats.totalDuration
        }

        // Estimate cost (rough: $3/M input, $15/M output for frontier models)
        stats.estimatedCost = (Double(stats.totalInput) * 3.0 / 1_000_000.0) + (Double(stats.totalOutput) * 15.0 / 1_000_000.0)

        return stats
    }

    private func costMetric(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: AppSpace.extraSmall) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(color.opacity(0.6))
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.muted)
                Text(value)
                    .font(AppFont.captionMedium)
                    .foregroundStyle(color)
            }
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return "\(String(format: "%.1f", Double(count) / 1_000_000))M" }
        if count >= 1_000 { return "\(String(format: "%.1f", Double(count) / 1_000))k" }
        return "\(count)"
    }

    private func formatCost(_ cost: Double) -> String {
        if cost < 0.001 { return "< $0.01" }
        if cost < 0.01 { return "~$0.01" }
        return "$\(String(format: "%.2f", cost))"
    }
}

// MARK: - Outcome Stats Panel (Self-Evolution Dashboard)

struct OutcomeStatsPanel: View {
    @State private var stats: [OutcomeStatsRow] = []
    @State private var toolStats: [ToolStatsRow] = []
    @State private var patterns: [PatternSummary] = []
    @State private var improvements: [SelfImprovementEngine.ImprovementRecord] = []
    @State private var diagnosis: SelfImprovementEngine.Diagnosis?
    @State private var promptStats: [PromptTagStatsRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.large) {
            // Header
            HStack {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Brand.primary)
                Text("自进化仪表盘")
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(TextGrade.primary)
                Spacer()
                Button { refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(TextGrade.muted)
                }
                .buttonStyle(.plain)
            }

            // 1. Health diagnosis
            diagnosisCard

            // 2. Task outcomes
            taskOutcomesSection

            // 3. Tool effectiveness
            toolEffectivenessSection

            // 4. Failure patterns
            failurePatternsSection

            // 5. Self-improvement history
            improvementHistorySection

            // 6. Prompt version comparison
            promptComparisonSection
        }
        .padding(AppSpace.medium)
        .onAppear { refresh() }
    }

    private func refresh() {
        stats = TaskOutcomeRecorder.shared.stats(days: 7)
        toolStats = TaskOutcomeRecorder.shared.toolStats(days: 7)
        patterns = FailurePatternDB.shared.topPatterns(limit: 5)
        improvements = SelfImprovementEngine.shared.recentImprovements(limit: 10)
        diagnosis = SelfImprovementEngine.shared.shouldTrigger()
        promptStats = TaskOutcomeRecorder.shared.promptTagStats(days: 7)
    }

    // MARK: - 1. Diagnosis Card

    @ViewBuilder
    private var diagnosisCard: some View {
        if let diagnosis {
            let color: Color = diagnosis.severity == .critical ? Semantic.error : Semantic.warning
            VStack(alignment: .leading, spacing: AppSpace.small) {
                HStack(spacing: AppSpace.small) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(diagnosis.severity == .critical ? "需要自我改进" : "可优化")
                        .font(AppFont.captionMedium)
                        .foregroundStyle(color)
                    Spacer()
                    Text(diagnosis.category.rawValue)
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.ghost)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(color.opacity(0.12)))
                }
                Text(diagnosis.description)
                    .font(AppFont.caption)
                    .foregroundStyle(TextGrade.secondary)
                    .lineLimit(3)
            }
            .padding(AppSpace.medium)
            .background(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous).fill(color.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous).strokeBorder(color.opacity(0.2), lineWidth: 0.5))
        } else {
            HStack(spacing: AppSpace.small) {
                Circle().fill(Semantic.success).frame(width: 8, height: 8)
                Text("系统健康")
                    .font(AppFont.captionMedium)
                    .foregroundStyle(Semantic.success)
                Spacer()
                Text("无需改进")
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
            }
            .padding(AppSpace.medium)
            .background(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous).fill(Semantic.success.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous).strokeBorder(Semantic.success.opacity(0.2), lineWidth: 0.5))
        }
    }

    // MARK: - 2. Task Outcomes

    @ViewBuilder
    private var taskOutcomesSection: some View {
        sectionHeader("会话完成率", icon: "chart.bar.fill")
        if stats.isEmpty {
            emptyHint(icon: "chart.bar", title: "暂无数据", hint: "会话完成后自动统计")
        } else {
            VStack(spacing: AppSpace.small) {
                ForEach(stats, id: \.intent) { row in
                    outcomeRow(row)
                }
            }
        }
    }

    @ViewBuilder
    private func outcomeRow(_ row: OutcomeStatsRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(intentLabel(row.intent))
                    .font(AppFont.captionMedium)
                    .foregroundStyle(TextGrade.primary)
                Spacer()
                Text("\(row.total) 次")
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.muted)
            }
            // Visual bar
            GeometryReader { geo in
                let width = geo.size.width
                let completedWidth = width * CGFloat(row.completionRate)
                let cancelledWidth = width * CGFloat(row.cancellationRate)
                ZStack(alignment: .leading) {
                    Capsule().fill(SurfaceGrade.sunken).frame(height: 6)
                    HStack(spacing: 0) {
                        Capsule().fill(Semantic.success).frame(width: max(0, completedWidth), height: 6)
                        Capsule().fill(Semantic.error.opacity(0.7)).frame(width: max(0, cancelledWidth), height: 6)
                    }
                }
            }
            .frame(height: 6)
            HStack(spacing: AppSpace.medium) {
                statPill("完成", value: "\(Int(row.completionRate * 100))%", color: row.completionRate > 0.7 ? Semantic.success : Semantic.warning)
                statPill("取消", value: "\(Int(row.cancellationRate * 100))%", color: row.cancellationRate < 0.2 ? Semantic.success : Semantic.error)
                statPill("迭代", value: String(format: "%.1f", row.avgIterations), color: row.avgIterations < 8 ? Brand.primary : Semantic.warning)
                if row.avgUserRating > 0 {
                    statPill("评分", value: String(format: "%.1f", row.avgUserRating), color: row.avgUserRating >= 4 ? Semantic.success : Semantic.warning)
                }
            }
        }
        .padding(AppSpace.small)
        .background(SurfaceGrade.card.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
    }

    // MARK: - 3. Tool Effectiveness

    @ViewBuilder
    private var toolEffectivenessSection: some View {
        if !toolStats.isEmpty {
            sectionHeader("工具效能", icon: "wrench.and.screwdriver.fill")
            VStack(spacing: AppSpace.extraSmall) {
                // Table header
                HStack {
                    Text("工具").font(AppFont.tiny).foregroundStyle(TextGrade.ghost).frame(width: 100, alignment: .leading)
                    Text("调用").font(AppFont.tiny).foregroundStyle(TextGrade.ghost).frame(width: 36, alignment: .trailing)
                    Text("成功率").font(AppFont.tiny).foregroundStyle(TextGrade.ghost).frame(width: 44, alignment: .trailing)
                    Text("均耗时").font(AppFont.tiny).foregroundStyle(TextGrade.ghost).frame(width: 44, alignment: .trailing)
                    Spacer()
                }
                ForEach(Array(toolStats.prefix(8).enumerated()), id: \.offset) { _, row in
                    toolRow(row)
                }
            }
        }
    }

    @ViewBuilder
    private func toolRow(_ row: ToolStatsRow) -> some View {
        let successRate = row.total > 0 ? Double(row.successes) / Double(row.total) : 1.0
        let rateColor: Color = successRate >= 0.9 ? Semantic.success : (successRate >= 0.7 ? Semantic.warning : Semantic.error)
        HStack {
            Text(row.toolName)
                .font(AppFont.tiny)
                .foregroundStyle(TextGrade.secondary)
                .lineLimit(1)
                .frame(width: 100, alignment: .leading)
            Text("\(row.total)")
                .font(AppFont.tiny)
                .foregroundStyle(TextGrade.muted)
                .frame(width: 36, alignment: .trailing)
            Text("\(Int(successRate * 100))%")
                .font(AppFont.tiny)
                .foregroundStyle(rateColor)
                .frame(width: 44, alignment: .trailing)
            Text(String(format: "%.1fs", row.avgDuration))
                .font(AppFont.tiny)
                .foregroundStyle(row.avgDuration < 5 ? TextGrade.muted : Semantic.warning)
                .frame(width: 44, alignment: .trailing)
            Spacer()
        }
        .padding(.vertical, 2)
    }

    // MARK: - 4. Failure Patterns

    @ViewBuilder
    private var failurePatternsSection: some View {
        if !patterns.isEmpty {
            sectionHeader("失败模式", icon: "exclamationmark.triangle.fill")
            VStack(spacing: AppSpace.extraSmall) {
                ForEach(Array(patterns.enumerated()), id: \.offset) { _, pattern in
                    HStack(spacing: AppSpace.small) {
                        Text("\(pattern.frequency)x")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(pattern.successAfterFix > 0 ? Semantic.success : Semantic.error)
                            .frame(width: 28, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(pattern.rootCause)
                                .font(AppFont.tiny)
                                .foregroundStyle(TextGrade.secondary)
                                .lineLimit(1)
                            Text("\(pattern.intent) · \(pattern.triggerTools)")
                                .font(.system(size: 9))
                                .foregroundStyle(TextGrade.ghost)
                                .lineLimit(1)
                        }
                        Spacer()
                        if pattern.successAfterFix > 0 {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Semantic.success)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - 5. Improvement History

    @ViewBuilder
    private var improvementHistorySection: some View {
        sectionHeader("自我改进记录", icon: "arrow.triangle.2.circlepath")
        if improvements.isEmpty {
            emptyHint(icon: "sparkles", title: "尚未触发", hint: "系统检测到性能问题时自动改进代码")
        } else {
            VStack(spacing: AppSpace.extraSmall) {
                ForEach(Array(improvements.prefix(5).enumerated()), id: \.offset) { _, record in
                    HStack(spacing: AppSpace.small) {
                        Image(systemName: record.buildSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(record.buildSuccess ? Semantic.success : Semantic.error)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(record.description)
                                .font(AppFont.tiny)
                                .foregroundStyle(TextGrade.secondary)
                                .lineLimit(2)
                            HStack(spacing: AppSpace.small) {
                                Text(record.category)
                                    .font(.system(size: 9))
                                    .foregroundStyle(TextGrade.ghost)
                                if !record.filesChanged.isEmpty {
                                    Text(record.filesChanged)
                                        .font(.system(size: 9))
                                        .foregroundStyle(TextGrade.ghost)
                                        .lineLimit(1)
                                }
                                Text(relativeTime(record.createdAt))
                                    .font(.system(size: 9))
                                    .foregroundStyle(TextGrade.ghost)
                            }
                        }
                        Spacer()
                        if let hash = record.commitHash {
                            Text(String(hash.prefix(7)))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Brand.primary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    // MARK: - 6. Prompt Comparison

    @ViewBuilder
    private var promptComparisonSection: some View {
        if !promptStats.isEmpty {
            sectionHeader("Prompt 版本", icon: "doc.text.fill")
            VStack(spacing: AppSpace.extraSmall) {
                ForEach(promptStats, id: \.tag) { row in
                    HStack {
                        Text(row.tag)
                            .font(AppFont.tiny)
                            .foregroundStyle(TextGrade.secondary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(row.total) 次 · \(Int(row.completionRate * 100))%")
                            .font(AppFont.tiny)
                            .foregroundStyle(TextGrade.muted)
                        if row.avgUserRating > 0 {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.yellow)
                            Text(String(format: "%.1f", row.avgUserRating))
                                .font(AppFont.tiny)
                                .foregroundStyle(TextGrade.muted)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func statPill(_ label: String, value: String, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(AppFont.captionMedium)
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(TextGrade.muted)
        }
    }

    private func intentLabel(_ intent: String) -> String {
        switch intent {
        case "chat": return "对话"
        case "research": return "研究"
        case "task": return "执行"
        default:
            if intent.hasPrefix("workflow:") { return "流程" }
            return intent
        }
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: AppSpace.extraSmall) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TextGrade.muted)
            Text(title)
                .font(AppFont.captionMedium)
                .foregroundStyle(TextGrade.primary)
        }
    }

    private func emptyHint(icon: String, title: String, hint: String) -> some View {
        VStack(spacing: AppSpace.extraSmall) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(TextGrade.muted.opacity(0.5))
            Text(title)
                .font(AppFont.caption)
                .foregroundStyle(TextGrade.muted)
            Text(hint)
                .font(AppFont.tiny)
                .foregroundStyle(TextGrade.muted.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpace.large)
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 3600 { return "\(Int(interval / 60))分钟前" }
        if interval < 86400 { return "\(Int(interval / 3600))小时前" }
        return "\(Int(interval / 86400))天前"
    }
}
