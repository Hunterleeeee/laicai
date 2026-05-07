import SwiftUI
import LaicaiNativeDomain
import LaicaiNativeFoundation

// MARK: - Connectors Panel

struct ConnectorsPanel: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingAddSheet = false
    @State private var editingConnector: ConnectorProfile?
    @State private var deletingConnector: ConnectorProfile?
    @State private var isCheckingAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            // Header with actions
            HStack(spacing: AppSpace.sm) {
                Image(systemName: "link")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.primary)
                Text("连接器")
                    .font(AppFont.subheadline)
                    .foregroundStyle(TextGrade.primary)
                Spacer()
                if !store.state.connectors.isEmpty {
                    Button {
                        isCheckingAll = true
                        store.checkAllConnectorsHealth()
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(3))
                            isCheckingAll = false
                        }
                    } label: {
                        if isCheckingAll {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "heart.text.square")
                                .font(.system(size: 11))
                                .foregroundStyle(Brand.primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("全部健康检查")
                }
                Button { showingAddSheet = true } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.primary)
                }
                .buttonStyle(.plain)
                .help("添加连接器")
            }

            if store.state.connectors.isEmpty {
                emptyHint(
                    icon: "link.badge.plus",
                    title: "暂无连接器",
                    hint: "添加模型 API 或本地 Ollama"
                )
            } else {
                // Online / Offline summary
                let online = store.state.connectors.filter { $0.health == .ready }.count
                let total = store.state.connectors.count
                HStack(spacing: AppSpace.sm) {
                    Circle().fill(Semantic.success).frame(width: 6, height: 6)
                    Text("\(online)/\(total) 在线")
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.muted)
                    Spacer()
                    if let active = store.state.activeConnector {
                        Text(active.modelName.isEmpty ? active.name : active.modelName)
                            .font(AppFont.codeSmall)
                            .foregroundStyle(TextGrade.ghost)
                            .lineLimit(1)
                    }
                }

                VStack(spacing: AppSpace.xs) {
                    ForEach(store.state.connectors) { conn in
                        ConnectorRow(conn: conn)
                            .onTapGesture { store.selectConnector(id: conn.id) }
                            .contextMenu {
                                Button { store.checkConnectorHealth(id: conn.id) } label: {
                                    Label("健康检查", systemImage: "heart")
                                }
                                if conn.toolCallingCapability != nil {
                                    Button { store.clearLearnedToolCallingCapability(id: conn.id) } label: {
                                        Label("清除已学习兼容性", systemImage: "arrow.counterclockwise.circle")
                                    }
                                }
                                Button { editingConnector = conn } label: {
                                    Label("编辑", systemImage: "pencil")
                                }
                                Divider()
                                Button(role: .destructive) { deletingConnector = conn } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
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
        .sheet(item: $editingConnector) { conn in
            ConnectorEditSheet(mode: .edit(conn)) { updated in
                store.updateConnector(updated)
                ToastCenter.shared.success("已更新 \(updated.name)")
            } onSaveAndTest: { updated in
                store.updateConnector(updated)
                store.checkConnectorHealth(id: updated.id)
                ToastCenter.shared.show("正在测试 \(updated.name)")
            }
        }
        .alert("删除连接器", isPresented: Binding(
            get: { deletingConnector != nil },
            set: { if !$0 { deletingConnector = nil } }
        )) {
            Button("取消", role: .cancel) { deletingConnector = nil }
            Button("删除", role: .destructive) {
                if let conn = deletingConnector { store.deleteConnector(id: conn.id) }
                deletingConnector = nil
            }
        } message: {
            Text("删除后这个模型配置会从本机移除。")
        }
    }

    private func emptyHint(icon: String, title: String, hint: String) -> some View {
        VStack(spacing: AppSpace.md) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Brand.primary.opacity(0.5))
                .frame(width: 40, height: 40)
                .background(Circle().fill(Brand.primary.opacity(0.06)))
            VStack(spacing: AppSpace.xs) {
                Text(title)
                    .font(AppFont.captionMedium)
                    .foregroundStyle(TextGrade.secondary)
                Text(hint)
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpace.xl)
    }
}

struct ConnectorRow: View {
    let conn: ConnectorProfile
    @EnvironmentObject private var store: AppStore

    var body: some View {
        let capability = ConnectorCapabilityProfile.infer(for: conn, mode: store.state.settings.contextMode)
        HStack(spacing: AppSpace.sm) {
            // Status dot with glow
            Circle()
                .fill(conn.health.color)
                .frame(width: 7, height: 7)
                .shadow(color: conn.health.color.opacity(0.5), radius: 3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: AppSpace.xs) {
                    Text(conn.name)
                        .font(AppFont.captionMedium)
                        .foregroundStyle(TextGrade.primary)
                        .lineLimit(1)
                    if conn.id == store.state.activeConnectorID {
                        Text("使用中")
                            .font(AppFont.tiny)
                            .foregroundStyle(Brand.primary)
                    }
                }

                Text(connectorCapabilitySummary(for: conn, capability: capability))
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.muted)
                    .lineLimit(1)
            }

            Spacer()

            Text(conn.health.title)
                .font(AppFont.tiny)
                .foregroundStyle(conn.health == .ready ? Semantic.success : conn.health.color)
                .padding(.horizontal, AppSpace.xs + 2)
                .padding(.vertical, 2)
                .background(Capsule().fill(conn.health.color.opacity(0.10)))
        }
        .padding(AppSpace.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(conn.id == store.state.activeConnectorID ? Brand.primary.opacity(0.06) : SurfaceGrade.card.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(
                    conn.id == store.state.activeConnectorID ? Brand.primary.opacity(0.15) : SurfaceGrade.border.opacity(0.3),
                    lineWidth: 0.5
                )
        )
    }
}

// MARK: - Activity Panel

struct ActivityPanel: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var composition = SkillCompositionEngine.shared
    @State private var isContextExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            // Header
            HStack(spacing: AppSpace.sm) {
                Image(systemName: "bolt.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(store.state.isGenerating ? Semantic.toolRunning : Brand.primary)
                Text("活动")
                    .font(AppFont.subheadline)
                    .foregroundStyle(TextGrade.primary)
                Spacer()
                if store.state.isGenerating {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("运行中")
                            .font(AppFont.tiny)
                            .foregroundStyle(Semantic.toolRunning)
                    }
                } else if let status = store.state.selectedThread?.status {
                    Text(status.label)
                        .font(AppFont.tiny)
                        .foregroundStyle(status.color)
                        .padding(.horizontal, AppSpace.sm)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(status.color.opacity(0.12)))
                }
            }

            // Live pipeline status
            if !composition.activePipelines.isEmpty {
                ForEach(composition.activePipelines) { pipe in
                    PipelineStatusCard(pipeline: pipe) {
                        composition.cancel(id: pipe.id)
                    }
                }
            }

            // Collapsible context card
            if let thread = store.state.selectedThread {
                DisclosureGroup(isExpanded: $isContextExpanded) {
                    let record = ThreadRecord(thread: thread, includeEvents: true)
                    VStack(alignment: .leading, spacing: AppSpace.sm) {
                        ThreadContextCard(
                            thread: record,
                            workspaceRoot: store.state.settings.workspacePath,
                            contextMode: store.state.settings.contextMode,
                            connector: connectorForThread(record)
                        )
                        if let metrics = latestMetrics(record) {
                            ResponseMetricsCard(metrics: metrics)
                        }
                        SessionCostCard(steps: thread.steps)
                    }
                } label: {
                    HStack(spacing: AppSpace.xs) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(TextGrade.muted)
                        Text("会话详情")
                            .font(AppFont.captionMedium)
                            .foregroundStyle(TextGrade.secondary)
                    }
                }
                .tint(TextGrade.muted)
            }

            // Activity list
            if store.state.toolActivities.isEmpty && composition.activePipelines.isEmpty {
                emptyActivity
            } else if !store.state.toolActivities.isEmpty {
                HStack {
                    Text("工具调用")
                        .font(AppFont.captionMedium)
                        .foregroundStyle(TextGrade.secondary)
                    Spacer()
                    Text("\(store.state.toolActivities.count) 次")
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.ghost)
                }
                VStack(spacing: AppSpace.xxs) {
                    ForEach(store.state.toolActivities.prefix(20)) { activity in
                        ActivityRow(activity: activity)
                    }
                }
            }

            // Recent pipeline history
            if !composition.history.isEmpty {
                HStack {
                    Text("管道历史")
                        .font(AppFont.captionMedium)
                        .foregroundStyle(TextGrade.secondary)
                    Spacer()
                    Text("\(composition.history.count) 条")
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.ghost)
                }
                VStack(spacing: AppSpace.xs) {
                    ForEach(composition.history.prefix(5)) { pipe in
                        PipelineHistoryRow(pipeline: pipe)
                    }
                }
            }
        }
    }

    private var emptyActivity: some View {
        VStack(spacing: AppSpace.md) {
            Image(systemName: "bolt.horizontal")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Brand.primary.opacity(0.5))
                .frame(width: 40, height: 40)
                .background(Circle().fill(Brand.primary.opacity(0.06)))
            VStack(spacing: AppSpace.xs) {
                Text("暂无活动")
                    .font(AppFont.captionMedium)
                    .foregroundStyle(TextGrade.secondary)
                Text("执行任务时会在这里显示进展")
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpace.xl)
    }

    private func quietThreadCard(_ thread: ThreadRecord) -> some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            HStack(spacing: AppSpace.sm) {
                Image(systemName: thread.status?.icon ?? (thread.isPinned ? "pin.fill" : "text.bubble"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(thread.status?.color ?? Brand.primary)
                Text("当前会话")
                    .font(AppFont.captionMedium)
                    .foregroundStyle(TextGrade.secondary)
                Spacer()
                Text(thread.status?.label ?? RelativeTimeFormatter.string(for: thread.updatedAt))
                    .font(AppFont.tiny)
                    .foregroundStyle(thread.status?.color ?? TextGrade.ghost)
            }

            Text(thread.title)
                .font(AppFont.bodyMedium)
                .foregroundStyle(TextGrade.primary)
                .lineLimit(3)

            if let latest = latestThreadSummary(thread) {
                Text(latest)
                    .font(AppFont.caption)
                    .foregroundStyle(TextGrade.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(AppSpace.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                            .fill(SurfaceGrade.sunken.opacity(0.48))
                    )
            }

            HStack(spacing: AppSpace.xs) {
                Label(thread.events.isEmpty ? "还没有记录" : "\(thread.events.count) 条记录", systemImage: "bubble.left.and.bubble.right")
                if let status = thread.status {
                    Label(status.label, systemImage: status.icon)
                }
            }
            .font(AppFont.tiny)
            .foregroundStyle(TextGrade.muted)
            .lineLimit(1)
        }
        .padding(AppSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).fill(SurfaceGrade.elevated.opacity(0.62)))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).strokeBorder((thread.status?.color ?? Brand.primary).opacity(0.14), lineWidth: 0.75))
    }

    private func connectorForThread(_ thread: ThreadRecord) -> ConnectorProfile? {
        if let connectorID = thread.task?.connectorID {
            return store.state.connectors.first(where: { $0.id == connectorID })
        }
        return store.state.activeConnector
    }

    private func latestMetrics(_ thread: ThreadRecord) -> ResponseMetrics? {
        thread.task?.steps.reversed().first(where: { $0.metrics != nil })?.metrics
            ?? thread.session?.turns.reversed().first(where: { $0.metrics != nil })?.metrics
    }

    private func latestThreadSummary(_ thread: ThreadRecord) -> String? {
        guard let text = thread.events.reversed().first(where: { event in
            !event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && event.kind != .user
        })?.text ?? thread.events.reversed().first(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.text else {
            return nil
        }
        let compact = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return nil }
        return compact.count > 180 ? String(compact.prefix(179)) + "…" : compact
    }
}

private struct ThreadContextCard: View {
    let thread: ThreadRecord
    let workspaceRoot: String
    let contextMode: ContextMode
    let connector: ConnectorProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.sm) {
            Text("运行上下文")
                .font(AppFont.captionMedium)
                .foregroundStyle(TextGrade.secondary)

            if let task = thread.task {
                if !task.context.workspaceRoot.isEmpty {
                    contextRow(icon: "folder", label: "工作区", value: task.context.workspaceRoot)
                }
                if let branch = task.context.gitBranch, !branch.isEmpty {
                    contextRow(icon: "arrow.triangle.branch", label: "分支", value: branch)
                }
                if let workflow = task.workflowName, !workflow.isEmpty {
                    contextRow(icon: "arrow.triangle.branch", label: "流程", value: workflow)
                }
                contextRow(icon: "doc.text", label: "文件", value: "\(task.context.relevantFiles.count) 项")
            } else {
                contextRow(icon: "folder", label: "工作区", value: workspaceRoot)
                contextRow(icon: "bubble.left.and.bubble.right", label: "记录", value: "\(thread.events.count) 条")
            }
        }
        .padding(AppSpace.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(SurfaceGrade.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(Brand.primary.opacity(0.15), lineWidth: 1)
        )
    }

    private func contextRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: AppSpace.sm) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(Brand.primary)
                .frame(width: 12)
            Text(label)
                .font(AppFont.tiny)
                .foregroundStyle(TextGrade.muted)
                .frame(width: 30, alignment: .leading)
            Spacer()
            Text(value)
                .font(AppFont.codeSmall)
                .foregroundStyle(TextGrade.secondary)
                .lineLimit(1)
        }
    }

}

private struct ModelContextCard: View {
    let connector: ConnectorProfile
    let contextMode: ContextMode

    var body: some View {
        let capability = ConnectorCapabilityProfile.infer(for: connector, mode: contextMode)
        contextSectionCard(title: "当前模型") {
            VStack(alignment: .leading, spacing: AppSpace.sm) {
                summaryRow(icon: "cpu", label: "模型", value: connector.modelName.isEmpty ? connector.name : connector.modelName)
                summaryRow(icon: "link", label: "连接", value: connector.name)
                summaryRow(icon: "wrench.and.screwdriver", label: "工具", value: connectorCapabilitySummary(for: connector, capability: capability))
                if let learned = learnedCapabilitySummary(for: capability) {
                    summaryRow(icon: "clock.arrow.circlepath", label: "记录", value: learned)
                }
                summaryRow(icon: "checkmark.circle", label: "状态", value: connector.health.title)
            }
        }
    }
}

private func connectorCapabilitySummary(for connector: ConnectorProfile, capability: ConnectorCapabilityProfile) -> String {
    let model = connector.modelName.isEmpty ? connector.kind : connector.modelName
    let tools = capability.supportsToolCalling ? "支持工具调用" : "不支持工具调用"
    return "\(model) · \(tools) · \(capability.speedTier.title) · \(capability.stabilityScore.title)"
}

private func learnedCapabilitySummary(for capability: ConnectorCapabilityProfile) -> String? {
    guard let learned = capability.learnedToolCallingDetail else { return nil }
    if let learnedAt = capability.learnedToolCallingLearnedAt {
        return "\(learned) · \(RelativeTimeFormatter.string(for: learnedAt))"
    }
    return learned
}

private struct ResponseMetricsCard: View {
    let metrics: ResponseMetrics

    var body: some View {
        contextSectionCard(title: "输出指标") {
            VStack(alignment: .leading, spacing: AppSpace.sm) {
                if let thinking = metrics.thinkingDuration {
                    summaryRow(icon: "brain", label: "思考", value: formatSeconds(thinking))
                }
                if let input = metrics.inputTokens {
                    summaryRow(icon: "arrow.down.left", label: "输入", value: "\(input) 词元")
                }
                if let output = metrics.outputTokens {
                    summaryRow(icon: "arrow.up.right", label: "输出", value: "\(output) 词元")
                }
                if let speed = metrics.tokensPerSecond, speed.isFinite {
                    summaryRow(icon: "speedometer", label: "速度", value: "\(String(format: "%.1f", speed)) 词元/秒")
                }
            }
        }
    }

    private func formatSeconds(_ value: TimeInterval) -> String {
        if value < 10 {
            return "\(String(format: "%.1f", value))s"
        }
        return "\(Int(value.rounded()))s"
    }
}

private struct RelatedFilesCard: View {
    let files: [FileInfo]

    var body: some View {
        contextSectionCard(title: "相关文件") {
            VStack(alignment: .leading, spacing: AppSpace.xs) {
                ForEach(Array(files.prefix(6))) { file in
                    HStack(alignment: .top, spacing: AppSpace.sm) {
                        Image(systemName: fileIcon(for: file.language))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Brand.primary)
                            .frame(width: 12, height: 12)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.path)
                                .font(AppFont.captionMedium)
                                .foregroundStyle(TextGrade.primary)
                                .lineLimit(1)
                            if !file.summary.isEmpty {
                                Text(compactSummary(file.summary))
                                    .font(AppFont.tiny)
                                    .foregroundStyle(TextGrade.muted)
                                    .lineLimit(2)
                            }
                        }

                        Spacer(minLength: AppSpace.sm)

                        if !file.language.isEmpty {
                            Text(file.language.uppercased())
                                .font(AppFont.tiny)
                                .foregroundStyle(TextGrade.ghost)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func fileIcon(for language: String) -> String {
        switch language.lowercased() {
        case "swift": return "swift"
        case "md", "txt": return "doc.text"
        case "json", "yaml", "yml", "toml": return "curlybraces"
        default: return "doc"
        }
    }

    private func compactSummary(_ summary: String) -> String {
        summary
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct CurrentFocusCard: View {
    enum Tone {
        case neutral
        case error

        var tint: Color {
            switch self {
            case .neutral: return Brand.primary
            case .error: return Semantic.error
            }
        }
    }

    let title: String
    let text: String
    let tone: Tone

    var body: some View {
        contextSectionCard(title: title, tint: tone.tint) {
            Text(text)
                .font(AppFont.caption)
                .foregroundStyle(TextGrade.secondary)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ActivityRow: View {
    let activity: ToolActivity

    var body: some View {
        HStack(alignment: .top, spacing: AppSpace.sm) {
            Image(systemName: activity.isFailure ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 18, height: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: AppSpace.xs) {
                HStack(spacing: AppSpace.xs) {
                    Text(activity.summary.isEmpty ? activity.name : activity.summary)
                        .font(AppFont.captionMedium)
                        .foregroundStyle(TextGrade.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: AppSpace.sm)

                    Text(RelativeTimeFormatter.string(for: activity.timestamp))
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.ghost)
                        .lineLimit(1)
                }

                if !activity.statusLine.isEmpty {
                    Text(activity.statusLine)
                        .font(AppFont.tiny)
                        .foregroundStyle(activity.isFailure ? Semantic.error : TextGrade.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !activity.name.isEmpty && activity.name != activity.summary {
                    Text(activity.name)
                        .font(AppFont.codeSmall)
                        .foregroundStyle(TextGrade.ghost)
                        .lineLimit(1)
                }
            }
        }
        .padding(AppSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(statusColor.opacity(activity.isFailure ? 0.08 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(statusColor.opacity(activity.isFailure ? 0.15 : 0.08), lineWidth: 0.5)
        )
    }

    private var statusColor: Color {
        activity.isFailure ? Semantic.error : Semantic.success
    }
}
