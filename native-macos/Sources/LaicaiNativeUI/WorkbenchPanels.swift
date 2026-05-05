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
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { isCheckingAll = false }
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

private func contextSectionCard<Content: View>(
    title: String,
    tint: Color = Brand.primary,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: AppSpace.sm) {
        Text(title)
            .font(AppFont.captionMedium)
            .foregroundStyle(TextGrade.secondary)
        content()
    }
    .padding(AppSpace.md)
    .background(
        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
            .fill(SurfaceGrade.card.opacity(0.4))
    )
    .overlay(
        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
            .strokeBorder(tint.opacity(0.10), lineWidth: 0.5)
    )
}

private func summaryRow(icon: String, label: String, value: String) -> some View {
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

// MARK: - Workflows Panel

struct WorkflowsPanel: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedWorkflow: WorkflowDefinition?
    @State private var showEditor = false
    @State private var searchText = ""
    @ObservedObject private var chainRegistry = WorkflowChainRegistry.shared

    var body: some View {
        let allWorkflows = WorkflowLibrary.available(workspaceRoot: store.state.settings.workspacePath)
        let workflows = searchText.isEmpty ? allWorkflows : allWorkflows.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText)
        }
        let loadErrors = WorkflowLibrary.shared.lastLoadErrors

        VStack(alignment: .leading, spacing: AppSpace.md) {
            // Header
            HStack(spacing: AppSpace.sm) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.primary)
                Text("工作流")
                    .font(AppFont.subheadline)
                    .foregroundStyle(TextGrade.primary)
                Spacer()
                Button { showEditor = true } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.primary)
                }
                .buttonStyle(.plain)
                .help("创建自定义工作流")
            }

            // Search
            if allWorkflows.count > 3 {
                HStack(spacing: AppSpace.sm) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(TextGrade.ghost)
                    TextField("搜索工作流…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(AppFont.caption)
                }
                .padding(AppSpace.sm)
                .background(RoundedRectangle(cornerRadius: AppRadius.sm).fill(SurfaceGrade.card))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.sm).strokeBorder(SurfaceGrade.hairline, lineWidth: 0.5))
            }

            // Workflows list
            if workflows.isEmpty {
                VStack(spacing: AppSpace.md) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(Brand.primary.opacity(0.4))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Brand.primary.opacity(0.06)))
                    VStack(spacing: AppSpace.xs) {
                        Text(searchText.isEmpty ? "暂无工作流" : "无匹配结果")
                            .font(AppFont.captionMedium)
                            .foregroundStyle(TextGrade.secondary)
                        Text(searchText.isEmpty ? "创建 YAML 工作流或点击 + 新建" : "尝试其他关键词")
                            .font(AppFont.tiny)
                            .foregroundStyle(TextGrade.muted)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpace.lg)
            } else {
                ForEach(workflows) { wf in
                    WorkflowRow(workflow: wf) {
                        selectedWorkflow = wf
                    }
                }
            }

            // Load errors
            if !loadErrors.isEmpty {
                VStack(alignment: .leading, spacing: AppSpace.xs) {
                    HStack(spacing: AppSpace.xs) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 9))
                            .foregroundStyle(Semantic.warning)
                        Text("\(loadErrors.count) 个加载错误")
                            .font(AppFont.tiny)
                            .foregroundStyle(Semantic.warning)
                    }
                    ForEach(loadErrors, id: \.self) { error in
                        Text(error)
                            .font(AppFont.codeSmall)
                            .foregroundStyle(TextGrade.muted)
                            .lineLimit(2)
                    }
                }
                .padding(AppSpace.sm)
                .background(RoundedRectangle(cornerRadius: AppRadius.sm).fill(Semantic.warningMuted.opacity(0.5)))
            }

            // Workflow chains
            if !chainRegistry.chains.isEmpty {
                HStack {
                    Text("工作流链")
                        .font(AppFont.captionMedium)
                        .foregroundStyle(TextGrade.secondary)
                    Spacer()
                    Text("\(chainRegistry.chains.count) 条")
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.ghost)
                }
                ForEach(chainRegistry.chains) { chain in
                    HStack(spacing: AppSpace.sm) {
                        Image(systemName: "link")
                            .font(.system(size: 9))
                            .foregroundStyle(Brand.purple)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(chain.name)
                                .font(AppFont.captionMedium)
                                .foregroundStyle(TextGrade.primary)
                                .lineLimit(1)
                            Text(chain.workflowNames.joined(separator: " → "))
                                .font(AppFont.tiny)
                                .foregroundStyle(TextGrade.muted)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            chainRegistry.removeChain(id: chain.id)
                            chainRegistry.save(workspaceRoot: store.state.settings.workspacePath)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(TextGrade.ghost)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(AppSpace.sm)
                    .background(RoundedRectangle(cornerRadius: AppRadius.sm).fill(SurfaceGrade.card.opacity(0.5)))
                }
            }

            // Run history
            if !store.state.workflowRuns.isEmpty {
                HStack {
                    Text("运行记录")
                        .font(AppFont.captionMedium)
                        .foregroundStyle(TextGrade.secondary)
                    Spacer()
                    Text("\(store.state.workflowRuns.count) 次")
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.ghost)
                }

                ForEach(store.state.workflowRuns) { run in
                    WorkflowRunRow(run: run)
                }
            }
        }
        .sheet(item: $selectedWorkflow) { wf in
            WorkflowLaunchSheet(workflow: wf) {
                selectedWorkflow = nil
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $showEditor) {
            WorkflowEditorView(isPresented: $showEditor)
                .environmentObject(store)
        }
    }

}

private struct WorkflowRow: View {
    let workflow: WorkflowDefinition
    let action: () -> Void
    @State private var isHovered = false

    private var categoryColor: Color {
        Color(hex: workflow.category.tintHex) ?? Brand.primary
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpace.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.sm)
                        .fill(categoryColor.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: workflow.category.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(categoryColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: AppSpace.xs) {
                        Text(workflow.name)
                            .font(AppFont.captionMedium)
                            .foregroundStyle(TextGrade.primary)
                        if !workflow.inputParams.isEmpty {
                            Text("\(workflow.inputParams.count) 参数")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(TextGrade.ghost)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(SurfaceGrade.base.opacity(0.5)))
                        }
                    }
                    Text(workflow.description)
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.muted)
                        .lineLimit(2)
                }

                Spacer()

                HStack(spacing: AppSpace.xs) {
                    Text("\(workflow.steps.count) 步")
                        .font(.system(size: 9))
                        .foregroundStyle(TextGrade.ghost)
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isHovered ? categoryColor : TextGrade.ghost)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(AppSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .fill(isHovered ? SurfaceGrade.hover : SurfaceGrade.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(isHovered ? categoryColor.opacity(0.2) : Color.clear, lineWidth: 0.6)
        )
        .onHover { isHovered = $0 }
    }
}

private struct WorkflowRunRow: View {
    let run: WorkflowRun

    var body: some View {
        HStack(spacing: AppSpace.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(run.name)
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.primary)
                    .lineLimit(1)
                Text(run.statusLine)
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.muted)
                    .lineLimit(1)
            }

            Spacer()

            Text(RelativeTimeFormatter.string(for: run.updatedAt))
                .font(AppFont.tiny)
                .foregroundStyle(TextGrade.ghost)
        }
        .padding(.vertical, AppSpace.xs)
    }
}

// MARK: - Skills Panel

struct SkillsPanel: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var registry = SkillRegistry.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            HStack {
                Text("技能")
                    .font(AppFont.subheadline)
                    .foregroundStyle(TextGrade.primary)
                Spacer()
                Button {
                    registry.refresh(workspaceRoot: store.state.settings.workspacePath)
                    ToastCenter.shared.success("已刷新技能")
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("刷新本地技能（读取 .laicai/skills 和 skills/*/skill.json）")

                Button {
                    createDraftSkill()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("从当前输入创建技能草稿")

                Text("\(registry.skills.count) 个")
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
            }

            if registry.skills.isEmpty {
                VStack(spacing: AppSpace.sm) {
                    Image(systemName: "star")
                        .font(.system(size: 24, weight: .ultraLight))
                        .foregroundStyle(TextGrade.ghost)
                    Text("暂无技能")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpace.xl)
            } else {
                Text("来源：内置技能、.laicai/skills/*.json、skills/*/skill.json")
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
                ForEach(registry.skills) { skill in
                    SkillRow(skill: skill) {
                        store.useSkill(skill)
                    }
                }
            }
        }
        .onAppear {
            registry.refresh(workspaceRoot: store.state.settings.workspacePath)
        }
        .onChange(of: store.state.settings.workspacePath) { newValue in
            registry.refresh(workspaceRoot: newValue)
        }
    }

    private func createDraftSkill() {
        let draft = store.state.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = draft.isEmpty ? "新技能 \(shortTimestamp())" : String(draft.prefix(18))
        let description = draft.isEmpty ? "本地技能草稿，可在 .laicai/skills 中继续编辑。" : draft

        do {
            _ = try registry.createDraft(
                name: name,
                description: description,
                tools: ["code.search", "file.read"],
                workspaceRoot: store.state.settings.workspacePath
            )
            ToastCenter.shared.success("已创建技能草稿")
        } catch {
            ToastCenter.shared.error(error.localizedDescription)
        }
    }

    private func shortTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        return formatter.string(from: Date())
    }
}

private struct SkillRow: View {
    let skill: SkillDefinition
    let action: () -> Void
    @EnvironmentObject private var store: AppStore
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: AppSpace.sm) {
            Button(action: action) {
                HStack(spacing: AppSpace.sm) {
                    ZStack {
                        RoundedRectangle(cornerRadius: AppRadius.sm)
                            .fill(Semantic.warningMuted)
                            .frame(width: 28, height: 28)
                        Image(systemName: skill.modelPreference.icon)
                            .font(.system(size: 11))
                            .foregroundStyle(Semantic.warning)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: AppSpace.xs) {
                            Text(skill.name)
                                .font(AppFont.captionMedium)
                                .foregroundStyle(TextGrade.primary)
                            if skill.isPublished {
                                Text("已发布")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(Semantic.success)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Semantic.success.opacity(0.10)))
                            }
                        }
                        Text(skill.description)
                            .font(AppFont.tiny)
                            .foregroundStyle(TextGrade.muted)
                            .lineLimit(2)
                    }

                    Spacer()

                    Image(systemName: skill.workflowName == nil ? "plus" : "play.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isHovered ? Brand.primary : TextGrade.ghost)
                }
            }
            .buttonStyle(.plain)

            if !skill.isBuiltin && !skill.isPublished {
                Button {
                    let didPublish = SkillRegistry.shared.publish(skillID: skill.id, workspaceRoot: store.state.settings.workspacePath)
                    if didPublish {
                        ToastCenter.shared.success("已发布「\(skill.name)」")
                    }
                } label: {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(TextGrade.muted)
                }
                .buttonStyle(.plain)
                .help("发布技能")
            }
        }
        .padding(AppSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .fill(isHovered ? SurfaceGrade.hover : SurfaceGrade.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(isHovered ? Brand.primary.opacity(0.15) : Color.clear, lineWidth: 0.6)
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - Agents Panel (Production)

struct AgentsPanel: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var agentReg = AgentRegistry.shared
    @ObservedObject private var toolReg = CustomToolRegistry.shared
    @State private var showAgentSheet = false
    @State private var showToolSheet = false
    @State private var editingAgent: CustomAgentDefinition?
    @State private var editingTool: CustomToolDefinition?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.xl) {
            agentSection
            Rectangle().fill(SurfaceGrade.divider).frame(height: 1).padding(.horizontal, -AppSpace.md)
            toolSection
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

    // MARK: - Agent Section

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            // Section header
            HStack(spacing: AppSpace.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Brand.primary.opacity(0.1))
                        .frame(width: 24, height: 24)
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Brand.primary)
                }
                Text("Agent")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TextGrade.primary)
                if !agentReg.agents.isEmpty {
                    Text("\(agentReg.agents.count)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(TextGrade.ghost)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(SurfaceGrade.elevated.opacity(0.6)))
                }
                Spacer()
                Button { editingAgent = nil; showAgentSheet = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                        Text("新建")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(Brand.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(Brand.primary.opacity(0.08))
                    )
                    .overlay(
                        Capsule().strokeBorder(Brand.primary.opacity(0.15), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }

            if agentReg.agents.isEmpty {
                VStack(spacing: AppSpace.md) {
                    ZStack {
                        Circle()
                            .fill(SurfaceGrade.card)
                            .frame(width: 52, height: 52)
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(TextGrade.ghost)
                    }
                    VStack(spacing: 3) {
                        Text("创建你的第一个 Agent")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(TextGrade.secondary)
                        Text("自定义角色、提示词和工具集")
                            .font(.system(size: 10))
                            .foregroundStyle(TextGrade.ghost)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpace.xl)
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

    // MARK: - Tool Section

    private var toolSection: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            // Section header
            HStack(spacing: AppSpace.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Semantic.warning.opacity(0.1))
                        .frame(width: 24, height: 24)
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Semantic.warning)
                }
                Text("自定义工具")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TextGrade.primary)
                if !toolReg.tools.isEmpty {
                    Text("\(toolReg.tools.count)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(TextGrade.ghost)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(SurfaceGrade.elevated.opacity(0.6)))
                }
                Spacer()
                Button { editingTool = nil; showToolSheet = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                        Text("新建")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(Semantic.warning)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(Semantic.warning.opacity(0.08))
                    )
                    .overlay(
                        Capsule().strokeBorder(Semantic.warning.opacity(0.15), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }

            if toolReg.tools.isEmpty {
                VStack(spacing: AppSpace.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(SurfaceGrade.card)
                            .frame(width: 48, height: 48)
                        Image(systemName: "hammer")
                            .font(.system(size: 20, weight: .light))
                            .foregroundStyle(TextGrade.ghost)
                    }
                    VStack(spacing: 3) {
                        Text("创建自定义工具")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(TextGrade.secondary)
                        Text("Shell · HTTP · 脚本")
                            .font(.system(size: 10))
                            .foregroundStyle(TextGrade.ghost)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpace.lg)
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
                Image(systemName: "folder")
                    .font(.system(size: 8))
                Text(".laicai/tools/*.json")
                    .font(.system(size: 9, design: .monospaced))
            }
            .foregroundStyle(TextGrade.ghost)
        }
    }
}

// MARK: - Agent Card

private struct AgentCard: View {
    let agent: CustomAgentDefinition
    let onEdit: () -> Void
    let onChat: () -> Void
    let onDelete: () -> Void
    @State private var hovered = false

    private var roleColor: Color {
        switch agent.role {
        case .coder: return Color(hex: "10B981")
        case .reviewer: return Color(hex: "F59E0B")
        case .researcher: return Color(hex: "3B82F6")
        case .tester: return Color(hex: "8B5CF6")
        case .planner: return Color(hex: "06B6D4")
        }
    }

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
                    MiniBtn(icon: "bubble.left.fill", color: Brand.primary, tip: "对话") { onChat() }
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

// MARK: - Wiki Panel

struct WikiPanel: View {
    @EnvironmentObject private var store: AppStore
    @State private var topic = ""
    @State private var useWeb = false
    @State private var result: WikiBuildResult?
    @State private var streamingText = ""
    @State private var isRunning = false
    @State private var errorText: String?
    @State private var showingSources = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            // Header
            HStack(spacing: AppSpace.sm) {
                Image(systemName: "book.closed")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.primary)
                Text("Wiki")
                    .font(AppFont.subheadline)
                    .foregroundStyle(TextGrade.primary)
                Spacer()
                if let result {
                    wikiActions(result)
                }
            }

            // Input
            HStack(spacing: AppSpace.sm) {
                TextField("输入主题", text: $topic)
                    .textFieldStyle(.plain)
                    .font(AppFont.body)
                    .onSubmit { if canRun { runWiki(save: false) } }

                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        runWiki(save: false)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(canRun ? Brand.primary : TextGrade.ghost)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canRun)
                }
            }
            .padding(.horizontal, AppSpace.md)
            .padding(.vertical, AppSpace.sm)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .fill(SurfaceGrade.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .strokeBorder(SurfaceGrade.hairline, lineWidth: 0.75)
            )

            // Options pill
            HStack(spacing: AppSpace.sm) {
                wikiPill(label: "联网", icon: "globe", isOn: $useWeb)

                if let connector = store.state.activeConnector {
                    Text(connector.name)
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.ghost)
                        .lineLimit(1)
                } else {
                    Text("未连接模型")
                        .font(AppFont.tiny)
                        .foregroundStyle(Semantic.error)
                }

                Spacer()

                Text(vaultLabel)
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let errorText {
                CurrentFocusCard(title: "错误", text: errorText, tone: .error)
            }

            // Content area
            if isRunning && !streamingText.isEmpty {
                wikiStreamingContent
            } else if let result {
                wikiResultContent(result)
            } else if !WikiEngine.recentResults.isEmpty {
                wikiHistory
            } else {
                emptyWikiState
            }
        }
        .onAppear {
            if topic.isEmpty {
                topic = suggestedTopic
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func wikiActions(_ result: WikiBuildResult) -> some View {
        HStack(spacing: AppSpace.xs) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.renderedMarkdown, forType: .string)
                ToastCenter.shared.success("已复制")
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(TextGrade.muted)
            .help("复制 Markdown")

            if !result.saved {
                Button {
                    runWiki(save: true)
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(TextGrade.muted)
                .help("保存到 Vault")
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Semantic.success)
                    .help("已保存")
            }

            Button {
                self.result = nil
                self.streamingText = ""
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(TextGrade.ghost)
            .help("关闭")
        }
    }

    // MARK: - Streaming content

    private var wikiStreamingContent: some View {
        VStack(alignment: .leading, spacing: AppSpace.sm) {
            HStack(spacing: AppSpace.xs) {
                ProgressView()
                    .controlSize(.mini)
                Text("正在生成…")
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.muted)
            }
            wikiMarkdownView(streamingText)
        }
    }

    // MARK: - Result content

    @ViewBuilder
    private func wikiResultContent(_ result: WikiBuildResult) -> some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            // Meta bar
            HStack(spacing: AppSpace.md) {
                HStack(spacing: AppSpace.xs) {
                    Image(systemName: "link")
                        .font(.system(size: 9))
                        .foregroundStyle(TextGrade.ghost)
                    Text("\(result.sources.count) 来源")
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.muted)
                }
                .onTapGesture { showingSources.toggle() }

                Text(result.diffSummary)
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)

                Spacer()

                Text(result.notePath)
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            // Sources (collapsible)
            if showingSources && !result.sources.isEmpty {
                VStack(alignment: .leading, spacing: AppSpace.xs) {
                    ForEach(Array(result.sources.prefix(8).enumerated()), id: \.offset) { _, source in
                        WikiSourceRow(source: source)
                    }
                }
                .padding(AppSpace.sm)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                        .fill(SurfaceGrade.elevated.opacity(0.5))
                )
            }

            // Rendered markdown
            wikiMarkdownView(result.renderedMarkdown)
        }
    }

    // MARK: - Markdown view

    private func wikiMarkdownView(_ markdown: String) -> some View {
        let cleaned = Self.stripFrontmatter(markdown)
        let rendered: Text = {
            if let attributed = try? AttributedString(markdown: cleaned, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                return Text(attributed)
            }
            return Text(cleaned)
        }()

        return rendered
            .font(AppFont.body)
            .foregroundStyle(TextGrade.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpace.md)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .fill(SurfaceGrade.card)
            )
    }

    private static func stripFrontmatter(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else { return trimmed }
        let parts = trimmed.components(separatedBy: "---")
        guard parts.count >= 3 else { return trimmed }
        return parts.dropFirst(2).joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - History

    private var wikiHistory: some View {
        VStack(alignment: .leading, spacing: AppSpace.sm) {
            Text("最近")
                .font(AppFont.captionMedium)
                .foregroundStyle(TextGrade.secondary)

            ForEach(WikiEngine.recentResults.suffix(8).reversed()) { r in
                Button {
                    result = r
                    topic = r.topic
                } label: {
                    HStack(spacing: AppSpace.sm) {
                        Image(systemName: r.saved ? "checkmark.circle.fill" : "doc.text")
                            .font(.system(size: 10))
                            .foregroundStyle(r.saved ? Semantic.success : TextGrade.muted)
                        Text(r.topic)
                            .font(AppFont.caption)
                            .foregroundStyle(TextGrade.primary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(r.sources.count) 来源")
                            .font(AppFont.tiny)
                            .foregroundStyle(TextGrade.ghost)
                    }
                    .padding(.vertical, AppSpace.xs)
                    .padding(.horizontal, AppSpace.sm)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                            .fill(SurfaceGrade.elevated.opacity(0.4))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Empty state

    private var emptyWikiState: some View {
        VStack(spacing: AppSpace.md) {
            Image(systemName: "book.closed")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(TextGrade.ghost)
            Text("输入主题，用 AI 生成知识页")
                .font(AppFont.captionMedium)
                .foregroundStyle(TextGrade.secondary)
            Text("内容来自本地 Vault 笔记 + 模型知识")
                .font(AppFont.tiny)
                .foregroundStyle(TextGrade.ghost)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpace.xl)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(SurfaceGrade.elevated.opacity(0.58))
        )
    }

    // MARK: - Pill toggle

    private func wikiPill(label: String, icon: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                Text(label)
                    .font(AppFont.tiny)
            }
            .foregroundStyle(isOn.wrappedValue ? Brand.primary : TextGrade.muted)
            .padding(.horizontal, AppSpace.sm)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(isOn.wrappedValue ? Brand.primary.opacity(0.12) : SurfaceGrade.elevated.opacity(0.5))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isOn.wrappedValue ? Brand.primary.opacity(0.3) : Color.clear, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var canRun: Bool {
        !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isRunning
    }

    private var vaultRoot: String {
        let clean = store.state.settings.vaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? store.state.settings.workspacePath : clean
    }

    private var vaultLabel: String {
        URL(fileURLWithPath: vaultRoot).lastPathComponent
    }

    private var suggestedTopic: String {
        let latest = store.state.selectedThread?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return latest.isEmpty || latest == "新会话" ? "" : latest
    }

    private func runWiki(save: Bool) {
        let cleanTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTopic.isEmpty else { return }
        isRunning = true
        errorText = nil
        streamingText = ""

        Task {
            let built = await store.buildWikiTopic(
                topic: cleanTopic,
                vaultRoot: vaultRoot,
                save: save,
                useWeb: useWeb,
                onChunk: { chunk in
                    self.streamingText += chunk
                }
            )
            await MainActor.run {
                result = built
                streamingText = ""
                isRunning = false
                showingSources = false
                if save {
                    ToastCenter.shared.success("已保存 Wiki：\(built.notePath)")
                }
            }
        }
    }
}

private struct WikiSourceRow: View {
    let source: WikiSource

    var body: some View {
        HStack(alignment: .top, spacing: AppSpace.sm) {
            Image(systemName: source.kind == "web" ? "globe" : "doc.text")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Brand.primary)
                .frame(width: 12)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                    .font(AppFont.captionMedium)
                    .foregroundStyle(TextGrade.primary)
                    .lineLimit(1)
                Text(source.path)
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
                    .lineLimit(1)
                if !source.preview.isEmpty {
                    Text(source.preview)
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.muted)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Pipeline Status Card

private struct PipelineStatusCard: View {
    let pipeline: SkillPipeline
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.sm) {
            HStack(spacing: AppSpace.sm) {
                Image(systemName: "arrow.forward.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Semantic.toolRunning)
                Text(pipeline.name)
                    .font(AppFont.captionMedium)
                    .foregroundStyle(TextGrade.primary)
                    .lineLimit(1)
                Spacer()
                Button { onCancel() } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Semantic.error)
                }
                .buttonStyle(.plain)
                .help("取消管道")
            }

            ForEach(pipeline.steps) { step in
                HStack(spacing: AppSpace.sm) {
                    Image(systemName: stepIcon(step.status))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(stepColor(step.status))
                        .frame(width: 14)
                    Text(step.skillName)
                        .font(AppFont.tiny)
                        .foregroundStyle(step.status == .running ? TextGrade.primary : TextGrade.muted)
                        .lineLimit(1)
                    Spacer()
                    if step.status == .running {
                        ProgressView().controlSize(.mini)
                    } else if step.status == .completed, let output = step.output {
                        Text(String(output.prefix(30)))
                            .font(AppFont.codeSmall)
                            .foregroundStyle(TextGrade.ghost)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(AppSpace.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(Semantic.toolRunning.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(Semantic.toolRunning.opacity(0.2), lineWidth: 0.75)
        )
    }

    private func stepIcon(_ status: PipelineStepStatus) -> String {
        switch status {
        case .pending: return "circle"
        case .running: return "circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .skipped: return "arrow.right.circle"
        }
    }

    private func stepColor(_ status: PipelineStepStatus) -> Color {
        switch status {
        case .pending: return TextGrade.ghost
        case .running: return Semantic.toolRunning
        case .completed: return Semantic.success
        case .failed: return Semantic.error
        case .skipped: return TextGrade.muted
        }
    }
}

private struct PipelineHistoryRow: View {
    let pipeline: SkillPipeline

    var body: some View {
        HStack(spacing: AppSpace.sm) {
            Image(systemName: pipeline.status == .completed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(pipeline.status == .completed ? Semantic.success : Semantic.error)
            VStack(alignment: .leading, spacing: 1) {
                Text(pipeline.name)
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.primary)
                    .lineLimit(1)
                Text("\(pipeline.steps.count) 步 · \(pipeline.steps.filter { $0.status == .completed }.count) 完成")
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
            }
            Spacer()
            if let completed = pipeline.completedAt {
                Text(RelativeTimeFormatter.string(for: completed))
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
            }
        }
        .padding(.vertical, AppSpace.xs)
    }
}

// MARK: - Diagnostics Panel

struct DiagnosticsPanel: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var auditLog = AuditLog.shared
    @State private var confirmClearAudit = false
    @State private var copiedDiagnostics = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            // Header
            HStack(spacing: AppSpace.sm) {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.primary)
                Text("日志")
                    .font(AppFont.subheadline)
                    .foregroundStyle(TextGrade.primary)
                Spacer()
                Button {
                    copyDiagnostics()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copiedDiagnostics ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9))
                        Text(copiedDiagnostics ? "已复制" : "复制诊断")
                            .font(AppFont.tiny)
                    }
                    .foregroundStyle(copiedDiagnostics ? Semantic.success : Brand.primary)
                }
                .buttonStyle(.plain)
                .help("复制完整诊断信息到剪贴板")
            }

            // System status
            VStack(spacing: 0) {
                diagRow("状态", store.state.isGenerating ? "生成中" : "空闲",
                        color: store.state.isGenerating ? Semantic.toolRunning : Semantic.success)
                Divider().opacity(0.3)
                diagRow("模型", store.state.activeConnector?.modelName ?? "未配置",
                        color: store.state.activeConnector != nil ? TextGrade.primary : Semantic.warning)
                Divider().opacity(0.3)
                diagRow("端点", store.state.activeConnector?.endpoint ?? "—", color: TextGrade.secondary)
            }
            .padding(AppSpace.sm)
            .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(SurfaceGrade.card))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md).strokeBorder(SurfaceGrade.border.opacity(0.3), lineWidth: 0.5))

            // Stats grid
            HStack(spacing: AppSpace.sm) {
                diagStatBadge(
                    icon: "text.bubble",
                    label: "会话",
                    value: "\(store.state.threads.filter { $0.source == .session }.count)",
                    color: Brand.primary
                )
                diagStatBadge(
                    icon: "checklist",
                    label: "任务",
                    value: "\(store.state.threads.filter { $0.source == .task }.count)",
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
            VStack(spacing: 0) {
                diagRow("工作区", URL(fileURLWithPath: store.state.settings.workspacePath).lastPathComponent, color: TextGrade.secondary)
                Divider().opacity(0.3)
                diagRow("上下文", store.state.settings.contextMode.rawValue, color: TextGrade.secondary)
                Divider().opacity(0.3)
                diagRow("系统", "\(ProcessInfo.processInfo.operatingSystemVersionString)", color: TextGrade.secondary)
                Divider().opacity(0.3)
                diagRow("内存", formatMemory(), color: TextGrade.secondary)
            }
            .padding(AppSpace.sm)
            .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(SurfaceGrade.card))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md).strokeBorder(SurfaceGrade.border.opacity(0.3), lineWidth: 0.5))

            // Audit log
            if auditLog.recentEntries.isEmpty {
                VStack(spacing: AppSpace.sm) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(TextGrade.ghost)
                    Text("暂无审计记录")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpace.lg)
            } else {
                HStack {
                    Text("审计记录")
                        .font(AppFont.captionMedium)
                        .foregroundStyle(TextGrade.secondary)
                    Spacer()
                    Text("\(auditLog.recentEntries.count) 条")
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.ghost)
                    Button {
                        confirmClearAudit = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 9))
                            .foregroundStyle(Semantic.error.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("清空审计记录")
                }

                VStack(spacing: AppSpace.xs) {
                    ForEach(auditLog.recentEntries.prefix(15)) { entry in
                        AuditEntryRow(entry: entry)
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
                    ForEach(store.state.toolActivities.prefix(10)) { a in
                        HStack {
                            Image(systemName: a.isFailure ? "xmark.circle" : "checkmark.circle")
                                .font(.system(size: 8))
                                .foregroundStyle(a.isFailure ? Semantic.error : Semantic.success)
                            Text(a.name)
                                .font(AppFont.codeSmall)
                                .foregroundStyle(TextGrade.primary)
                                .lineLimit(1)
                            Spacer()
                            Text(a.isFailure ? "失败" : "成功")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(a.isFailure ? Semantic.error : Semantic.success)
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
        .padding(.vertical, AppSpace.sm)
        .background(RoundedRectangle(cornerRadius: AppRadius.sm).fill(color.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.sm).strokeBorder(color.opacity(0.12), lineWidth: 0.5))
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
            "状态: \(store.state.isGenerating ? "生成中" : "空闲")",
            "模型: \(conn?.modelName ?? "未配置")",
            "端点: \(conn?.endpoint ?? "—")",
            "工作区: \(store.state.settings.workspacePath)",
            "上下文模式: \(store.state.settings.contextMode.rawValue)",
            "会话: \(store.state.threads.filter { $0.source == .session }.count)",
            "任务: \(store.state.threads.filter { $0.source == .task }.count)",
            "工具活动: \(store.state.toolActivities.count)",
            "审计: \(auditLog.recentEntries.count)",
            "内存: \(formatMemory())",
            "系统: \(ProcessInfo.processInfo.operatingSystemVersionString)",
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copiedDiagnostics = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedDiagnostics = false }
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
        let t = entry.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        // For file paths, show just the filename
        if t.contains("/") {
            return URL(fileURLWithPath: t).lastPathComponent
        }
        return String(t.prefix(40))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }) {
                HStack(alignment: .center, spacing: AppSpace.sm) {
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
            .buttonStyle(.plain)

            if isExpanded && hasDetails {
                VStack(alignment: .leading, spacing: AppSpace.xs) {
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
                .padding(.top, AppSpace.xs)
            }
        }
        .padding(AppSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(entry.success ? SurfaceGrade.card.opacity(0.72) : Semantic.errorMuted.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(entry.success ? SurfaceGrade.divider : Semantic.error.opacity(0.18), lineWidth: 0.75)
        )
    }

    private var hasDetails: Bool {
        !entry.input.isEmpty || !entry.output.isEmpty || (entry.action != "tool_call" && !entry.action.isEmpty)
    }

    private func auditDetailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: AppSpace.xs) {
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

    private func displayToolName(_ name: String) -> String {
        switch name {
        case "file.write": return "文件写入"
        case "file.edit": return "文件编辑"
        case "file.read": return "文件读取"
        case "file.rollback": return "文件回滚"
        case "code.search": return "项目搜索"
        case "shell.exec": return "命令执行"
        case "workspace.index": return "项目索引"
        case "git": return "Git 操作"
        case "git.reset": return "Git 回滚"
        case "web.search": return "网页搜索"
        case "web.fetch": return "网页读取"
        case "wiki.build": return "知识页生成"
        case "image.generate": return "图片生成"
        case "batch.apply": return "批量写入"
        case "batch.rollback": return "批量回滚"
        default: return name.isEmpty ? "操作" : name
        }
    }
}

// MARK: - Resources Panel

struct ResourcesPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            Text("资源")
                .font(AppFont.subheadline)
                .foregroundStyle(TextGrade.primary)

            VStack(spacing: AppSpace.sm) {
                Image(systemName: "folder")
                    .font(.system(size: 32, weight: .ultraLight))
                    .foregroundStyle(TextGrade.ghost)
                Text("暂无资源")
                    .font(AppFont.caption)
                    .foregroundStyle(TextGrade.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpace.xl)
        }
    }
}

// MARK: - Session Cost Card

private struct SessionCostCard: View {
    let steps: [TaskStep]

    var body: some View {
        let stats = aggregateMetrics()
        if stats.totalInput > 0 || stats.totalOutput > 0 {
            contextSectionCard(title: "会话消耗") {
                VStack(alignment: .leading, spacing: AppSpace.sm) {
                    HStack(spacing: AppSpace.lg) {
                        costMetric(icon: "arrow.down.left", label: "输入", value: formatTokens(stats.totalInput), color: Brand.primary)
                        costMetric(icon: "arrow.up.right", label: "输出", value: formatTokens(stats.totalOutput), color: Brand.purple)
                    }

                    Divider().opacity(0.3)

                    HStack(spacing: AppSpace.lg) {
                        costMetric(icon: "sum", label: "总计", value: formatTokens(stats.totalInput + stats.totalOutput), color: TextGrade.primary)
                        costMetric(icon: "dollarsign.circle", label: "预估", value: formatCost(stats.estimatedCost), color: Semantic.warning)
                    }

                    if stats.requestCount > 1 {
                        HStack(spacing: AppSpace.lg) {
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
            if let m = step.metrics {
                stats.totalInput += m.inputTokens ?? 0
                stats.totalOutput += m.outputTokens ?? 0
                stats.totalDuration += m.totalDuration
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
        HStack(spacing: AppSpace.xs) {
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

// MARK: - Outcome Stats Panel

struct OutcomeStatsPanel: View {
    @State private var stats: [OutcomeStatsRow] = []
    @State private var promptStats: [PromptTagStatsRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            sectionHeader("自进化指标")

            if stats.isEmpty {
                emptyHint(icon: "chart.bar", title: "暂无数据", hint: "完成任务后自动统计")
            } else {
                VStack(spacing: AppSpace.sm) {
                    ForEach(stats, id: \.intent) { row in
                        outcomeRow(row)
                    }
                }

                if !promptStats.isEmpty {
                    Divider().padding(.vertical, AppSpace.xs)
                    Text("Prompt 版本对比")
                        .font(AppFont.captionMedium)
                        .foregroundStyle(TextGrade.secondary)
                    VStack(spacing: AppSpace.xs) {
                        ForEach(promptStats, id: \.tag) { row in
                            promptRow(row)
                        }
                    }
                }
            }
        }
        .padding(AppSpace.md)
        .onAppear { refresh() }
    }

    private func refresh() {
        stats = TaskOutcomeRecorder.shared.stats(days: 7)
        promptStats = TaskOutcomeRecorder.shared.promptTagStats(days: 7)
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
            HStack(spacing: AppSpace.md) {
                statPill("完成率", value: "\(Int(row.completionRate * 100))%", color: row.completionRate > 0.7 ? .green : .orange)
                statPill("取消率", value: "\(Int(row.cancellationRate * 100))%", color: row.cancellationRate < 0.2 ? .green : .red)
                statPill("迭代", value: String(format: "%.1f", row.avgIterations), color: row.avgIterations < 8 ? .blue : .orange)
                if row.avgUserRating > 0 {
                    statPill("评分", value: String(format: "%.1f", row.avgUserRating), color: row.avgUserRating >= 4 ? .green : .yellow)
                }
            }
        }
        .padding(AppSpace.sm)
        .background(SurfaceGrade.card.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }

    @ViewBuilder
    private func promptRow(_ row: PromptTagStatsRow) -> some View {
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
        case "chat": return "聊天"
        case "research": return "研究"
        case "task": return "任务"
        default:
            if intent.hasPrefix("workflow:") { return "工作流" }
            return intent
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(AppFont.bodyMedium)
            .foregroundStyle(TextGrade.primary)
    }

    private func emptyHint(icon: String, title: String, hint: String) -> some View {
        VStack(spacing: AppSpace.xs) {
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
        .padding(.vertical, AppSpace.lg)
    }
}
