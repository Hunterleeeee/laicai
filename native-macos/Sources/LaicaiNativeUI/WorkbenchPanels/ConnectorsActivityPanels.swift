import Foundation
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
            connectorOverview

            if store.state.connectors.isEmpty {
                emptyHint(
                    icon: "link.badge.plus",
                    title: "暂无连接器",
                    hint: "添加模型 API 或本地 Ollama"
                )
            } else {
                VStack(spacing: AppSpace.sm) {
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

    private var connectorOverview: some View {
        let online = store.state.connectors.filter { $0.health == .ready }.count
        let total = store.state.connectors.count
        let active = store.state.activeConnector

        return VStack(alignment: .leading, spacing: AppSpace.md) {
            HStack(alignment: .top, spacing: AppSpace.sm) {
                Image(systemName: active?.health == .ready ? "checkmark.seal.fill" : "link")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(active?.health == .ready ? Semantic.success : Brand.primary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill((active?.health == .ready ? Semantic.success : Brand.primary).opacity(0.10)))

                VStack(alignment: .leading, spacing: AppSpace.xs) {
                    Text(active == nil ? "模型连接" : (active?.modelName.isEmpty == false ? active?.modelName ?? "模型连接" : active?.name ?? "模型连接"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(TextGrade.primary)
                        .lineLimit(1)
                    Text(total == 0 ? "添加模型后即可开始使用。" : "\(online)/\(total) 在线 · 点击下方连接器即可切换")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                        .lineLimit(2)
                }

                Spacer()
            }

            HStack(spacing: AppSpace.xs) {
                Button {
                    isCheckingAll = true
                    store.checkAllConnectorsHealth()
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(3))
                        isCheckingAll = false
                    }
                } label: {
                    Label(isCheckingAll ? "检查中" : "检查", systemImage: isCheckingAll ? "arrow.triangle.2.circlepath" : "heart.text.square")
                        .font(AppFont.captionMedium)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(total == 0 ? TextGrade.ghost : Brand.primary)
                .padding(.vertical, AppSpace.sm)
                .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(SurfaceGrade.card.opacity(0.60)))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.md).strokeBorder(SurfaceGrade.hairline.opacity(0.8), lineWidth: 0.6))
                .disabled(total == 0)

                Button { showingAddSheet = true } label: {
                    Label("添加", systemImage: "plus")
                        .font(AppFont.captionMedium)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.primary)
                .padding(.vertical, AppSpace.sm)
                .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Brand.primary.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.md).strokeBorder(Brand.primary.opacity(0.18), lineWidth: 0.6))
            }
        }
        .padding(AppSpace.lg)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .fill(LinearGradient(colors: [SurfaceGrade.card, SurfaceGrade.elevated.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(SurfaceGrade.hairline.opacity(0.9), lineWidth: 0.7)
        )
        .shadow(color: AppShadow.sm.color, radius: AppShadow.sm.radius, y: AppShadow.sm.y)
    }

    private func emptyHint(icon: String, title: String, hint: String) -> some View {
        VStack(spacing: AppSpace.md) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Brand.primary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Brand.primary.opacity(0.10)))
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
        .padding(.vertical, AppSpace.lg)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .fill(SurfaceGrade.card.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(SurfaceGrade.hairline.opacity(0.75), lineWidth: 0.6)
        )
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
                .fill(
                    conn.id == store.state.activeConnectorID
                        ? AnyShapeStyle(LinearGradient(colors: [Brand.primary.opacity(0.12), SurfaceGrade.card.opacity(0.86)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(SurfaceGrade.card.opacity(0.72))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(
                    conn.id == store.state.activeConnectorID ? Brand.primary.opacity(0.24) : SurfaceGrade.hairline.opacity(0.75),
                    lineWidth: 0.7
                )
        )
        .shadow(color: conn.id == store.state.activeConnectorID ? AppShadow.sm.color : .clear, radius: AppShadow.sm.radius, y: AppShadow.sm.y)
    }
}

// MARK: - Activity Panel

struct ActivityPanel: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var composition = SkillCompositionEngine.shared
    @ObservedObject private var projectManager = ProjectManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            currentThreadSection
            modelSection
            recentActivitySection
            commandSection
        }
    }

    private var modelSection: some View {
        let active = store.state.activeConnector
        let profile = ConnectorCapabilityProfile.infer(for: active, mode: store.state.settings.contextMode)

        return InspectorBlock(title: "模型", trailing: AnyView(modelHealthBadge(active))) {
            VStack(alignment: .leading, spacing: AppSpace.sm) {
                Menu {
                    ForEach(store.state.connectors) { connector in
                        Button {
                            store.selectConnector(id: connector.id)
                        } label: {
                            Label(
                                connector.modelName.isEmpty ? connector.name : connector.modelName,
                                systemImage: connector.id == store.state.activeConnectorID ? "checkmark.circle.fill" : "cpu"
                            )
                        }
                    }
                    if store.state.connectors.isEmpty {
                        Text("暂无连接器")
                    }
                    Divider()
                    if let connector = active {
                        Button {
                            store.checkConnectorHealth(id: connector.id)
                        } label: {
                            Label("测试当前模型", systemImage: "heart.text.square")
                        }
                    }
                    Button {
                        NotificationCenter.default.post(name: .laicaiOpenSettings, object: nil)
                    } label: {
                        Label("管理连接器", systemImage: "gearshape")
                    }
                } label: {
                    HStack(alignment: .center, spacing: AppSpace.sm) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(activeModelTitle)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(TextGrade.primary)
                                .lineLimit(1)
                            Text(active?.name ?? "在设置里添加 API 或本地 Ollama")
                                .font(AppFont.tiny)
                                .foregroundStyle(TextGrade.muted)
                                .lineLimit(1)
                        }

                        Spacer(minLength: AppSpace.sm)

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(TextGrade.ghost)
                    }
                    .padding(AppSpace.sm)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                            .fill(SurfaceGrade.elevated.opacity(0.72))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                            .strokeBorder(SurfaceGrade.border.opacity(0.58), lineWidth: 0.7)
                    )
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)

                LazyVGrid(columns: twoColumns, spacing: AppSpace.xs) {
                    InspectorMetricTile(icon: "rectangle.compress.vertical", label: "窗口", value: compactTokenCount(profile.contextWindow), tint: Brand.primary)
                    InspectorMetricTile(icon: profile.supportsToolCalling ? "checkmark.seal" : "slash.circle", label: "工具", value: profile.supportsToolCalling ? "可用" : "关闭", tint: profile.supportsToolCalling ? Semantic.success : TextGrade.ghost)
                }
            }
        }
    }

    private var currentThreadSection: some View {
        Group {
            if let thread = store.state.selectedThread {
                InspectorBlock(title: "线程", trailing: AnyView(statusBadge(for: thread))) {
                    VStack(alignment: .leading, spacing: AppSpace.md) {
                        HStack(alignment: .top, spacing: AppSpace.md) {
                            ZStack {
                                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                                    .fill(statusTint(for: thread).opacity(0.12))
                                    .frame(width: 38, height: 38)
                                Image(systemName: pulseIcon(for: thread))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(statusTint(for: thread))
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(agentTitle(for: thread))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(TextGrade.primary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(pulseSummary(for: thread))
                                    .font(AppFont.caption)
                                    .foregroundStyle(TextGrade.secondary)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        LazyVGrid(columns: twoColumns, spacing: AppSpace.sm) {
                            ForEach(threadFacts(for: thread)) { fact in
                                InspectorMetricTile(icon: fact.icon, label: fact.title, value: fact.value, tint: fact.tint)
                            }
                        }

                        goalCard(for: thread)
                        agentPlanCard(for: thread)
                        agentLedgerCard(for: thread)
                        agentArtifactCard(for: thread)
                    }
                }
            } else {
                InspectorBlock(title: "当前会话") {
                    InspectorEmptyRow(icon: "rectangle.stack", title: "没有选中会话", subtitle: "左侧选择一个会话，或直接在中间输入一个目标。")
                }
            }
        }
    }

    private var commandSection: some View {
        InspectorBlock(title: "操作") {
            LazyVGrid(columns: twoColumns, spacing: AppSpace.sm) {
                InspectorCommandTile(icon: "arrow.down.to.line.compact", title: "最新", tint: Brand.primary, isEnabled: store.state.selectedThread != nil) {
                    NotificationCenter.default.post(name: .laicaiScrollToBottom, object: nil)
                }
                InspectorCommandTile(icon: "arrow.clockwise", title: "重试", tint: Brand.purple, isEnabled: canRetry) {
                    store.retryLastMessage()
                }
                InspectorCommandTile(icon: "arrow.turn.down.right", title: "继续", tint: Brand.teal, isEnabled: canContinue) {
                    store.continueTask()
                }
                InspectorCommandTile(icon: "doc.on.doc", title: "复制", tint: TextGrade.muted, isEnabled: store.state.selectedThread != nil) {
                    if let markdown = store.exportSelectedThreadMarkdown() {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(markdown, forType: .string)
                        ToastCenter.shared.success("已复制当前会话")
                    }
                }
                if store.state.isGenerating {
                    InspectorCommandTile(icon: "stop.fill", title: "停止", tint: Semantic.error, isEnabled: true) {
                        store.stopGenerating()
                    }
                }
            }
        }
    }

    private var recentActivitySection: some View {
        let total = store.state.toolActivities.count + composition.activePipelines.count
        return InspectorBlock(title: "最近活动", trailing: total == 0 ? nil : AnyView(Text("\(total)").font(AppFont.tiny).foregroundStyle(TextGrade.ghost))) {
            VStack(spacing: 0) {
                if !composition.activePipelines.isEmpty {
                    ForEach(composition.activePipelines) { pipe in
                        InspectorActivityLine(icon: "arrow.triangle.branch", title: pipe.name, subtitle: "\(pipe.steps.count) 步 · 进行中", tint: Brand.teal)
                        if pipe.id != composition.activePipelines.last?.id || !store.state.toolActivities.isEmpty {
                            InspectorDivider()
                        }
                    }
                }
                if store.state.toolActivities.isEmpty && composition.activePipelines.isEmpty {
                    compactEmptyActivity
                } else {
                    ForEach(store.state.toolActivities.prefix(5)) { activity in
                        InspectorActivityLine(
                            icon: activity.isFailure ? "xmark.circle.fill" : "checkmark.circle.fill",
                            title: activity.summary.isEmpty ? activity.name : activity.summary,
                            subtitle: activity.statusLine.isEmpty ? RelativeTimeFormatter.string(for: activity.timestamp) : activity.statusLine,
                            tint: activity.isFailure ? Semantic.error : Semantic.success
                        )
                        if activity.id != store.state.toolActivities.prefix(5).last?.id {
                            InspectorDivider()
                        }
                    }
                }
            }
        }
    }

    private var compactEmptyActivity: some View {
        InspectorEmptyRow(icon: "sparkles", title: "暂无活动", subtitle: "工具、流程和错误会在这里汇总。")
    }

    private func goalCard(for thread: Thread) -> some View {
        let goal = thread.goal?.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: AppSpace.xs) {
            Text("目标")
                .font(AppFont.tiny)
                .foregroundStyle(TextGrade.muted)
            Text(goal?.isEmpty == false ? goal! : fallbackAgentGoal(for: thread))
                .font(AppFont.caption)
                .foregroundStyle(TextGrade.secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).fill(SurfaceGrade.elevated.opacity(0.62)))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).strokeBorder(SurfaceGrade.hairline.opacity(0.70), lineWidth: 0.6))
    }

    private func agentPlanCard(for thread: Thread) -> some View {
        let plan = thread.currentPlan.isEmpty ? inferredAgentPlan(for: thread) : thread.currentPlan
        return VStack(alignment: .leading, spacing: AppSpace.xs) {
            HStack {
                Text("当前计划")
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.muted)
                Spacer()
                Text(thread.executionState.title)
                    .font(AppFont.tiny)
                    .foregroundStyle(statusTint(for: thread))
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(plan.prefix(4).enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: AppSpace.xs) {
                        Text("\(index + 1)")
                            .font(AppFont.tiny)
                            .foregroundStyle(statusTint(for: thread))
                            .frame(width: 14, alignment: .leading)
                        Text(item)
                            .font(AppFont.caption)
                            .foregroundStyle(TextGrade.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(AppSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).fill(SurfaceGrade.card.opacity(0.64)))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).strokeBorder(SurfaceGrade.hairline.opacity(0.70), lineWidth: 0.6))
    }

    private func agentArtifactCard(for thread: Thread) -> some View {
        let artifacts = thread.artifacts.isEmpty ? inferredArtifacts(for: thread) : thread.artifacts
        return VStack(alignment: .leading, spacing: AppSpace.xs) {
            Text("证据与产物")
                .font(AppFont.tiny)
                .foregroundStyle(TextGrade.muted)
            if artifacts.isEmpty {
                Text("还没有生成可交付产物。")
                    .font(AppFont.caption)
                    .foregroundStyle(TextGrade.ghost)
            } else {
                ForEach(artifacts.prefix(3)) { artifact in
                    AgentArtifactRow(artifact: artifact)
                }
            }
        }
        .padding(AppSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).fill(SurfaceGrade.card.opacity(0.54)))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).strokeBorder(SurfaceGrade.hairline.opacity(0.65), lineWidth: 0.6))
    }

    private func agentLedgerCard(for thread: Thread) -> some View {
        let ledger = thread.executionLedger
        let readCount = ledger?.readFiles.count ?? 0
        let searchCount = ledger?.searches.count ?? 0
        let pageCount = ledger?.pages.count ?? 0
        let commandCount = ledger?.commands.count ?? 0
        let verificationCount = ledger?.verification.count ?? 0
        let evidenceCount = readCount + searchCount + pageCount + commandCount + verificationCount
        let modifiedCount = ledger?.modifiedFiles.count ?? 0
        let failedCount = ledger?.failedTools.count ?? 0
        let ledgerStateTitle = ledger?.state.title ?? "未建立"
        let nextAction = ledger?.nextAction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pendingFollowUp = ledger?.pendingFollowUp?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return VStack(alignment: .leading, spacing: AppSpace.xs) {
            HStack {
                Text("执行账本")
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.muted)
                Spacer()
                Text(ledgerStateTitle)
                    .font(AppFont.tiny)
                    .foregroundStyle(ledger == nil ? TextGrade.ghost : statusTint(for: thread))
            }

            LazyVGrid(columns: twoColumns, spacing: AppSpace.xs) {
                InspectorMetricTile(icon: "doc.text.magnifyingglass", label: "证据", value: "\(evidenceCount)", tint: Brand.primary)
                InspectorMetricTile(icon: "square.and.pencil", label: "改动", value: "\(modifiedCount)", tint: Brand.teal)
                InspectorMetricTile(icon: "checkmark.seal", label: "验证", value: "\(verificationCount)", tint: Semantic.success)
                InspectorMetricTile(icon: "exclamationmark.triangle", label: "失败", value: "\(failedCount)", tint: failedCount > 0 ? Semantic.error : TextGrade.ghost)
            }

            if !nextAction.isEmpty {
                Text("下一步：\(nextAction)")
                    .font(AppFont.caption)
                    .foregroundStyle(TextGrade.secondary)
                    .lineLimit(2)
            }
            if !pendingFollowUp.isEmpty {
                Text("排队补充：\(pendingFollowUp)")
                    .font(AppFont.caption)
                    .foregroundStyle(Brand.primary)
                    .lineLimit(2)
            }
            if ledger == nil {
                Text("旧会话会在下次继续或运行时自动建立账本。")
                    .font(AppFont.caption)
                    .foregroundStyle(TextGrade.ghost)
            }
        }
        .padding(AppSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).fill(SurfaceGrade.card.opacity(0.58)))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).strokeBorder(SurfaceGrade.hairline.opacity(0.65), lineWidth: 0.6))
    }

    private var canRetry: Bool {
        guard !store.state.isGenerating, let thread = store.state.selectedThread else { return false }
        return thread.steps.contains { $0.kind == .userInput }
    }

    private var canContinue: Bool {
        guard !store.state.isGenerating, let thread = store.state.selectedThread, thread.canContinue else { return false }
        return thread.status != .running
    }

    private func statusTint(for thread: Thread) -> Color {
        if store.state.isGenerating && thread.id == store.state.selectedThreadID { return Semantic.toolRunning }
        switch thread.executionState {
        case .running, .planning: return Semantic.toolRunning
        case .waitingForApproval: return Semantic.warning
        case .blocked, .failed: return Semantic.error
        case .paused: return TextGrade.muted
        case .completed: return Semantic.success
        case .idle, .archived: break
        }
        if thread.isExecution { return thread.status.color }
        return Brand.primary
    }

    private func pulseIcon(for thread: Thread) -> String {
        if store.state.isGenerating && thread.id == store.state.selectedThreadID { return "waveform.path.ecg" }
        if thread.isExecution { return thread.status.icon }
        return thread.steps.isEmpty ? "text.bubble" : "bubble.left.and.bubble.right"
    }

    private func sourceTitle(for thread: Thread) -> String {
        if store.state.isGenerating && thread.id == store.state.selectedThreadID { return "正在处理" }
        return "线程"
    }

    private func statusBadge(for thread: Thread) -> some View {
        let tint = statusTint(for: thread)
        let label: String = {
            if store.state.isGenerating && thread.id == store.state.selectedThreadID { return "运行中" }
            return thread.executionState.title
        }()
        return Text(label)
            .font(AppFont.tiny)
            .foregroundStyle(tint)
            .padding(.horizontal, AppSpace.sm)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    private func modelHealthBadge(_ connector: ConnectorProfile?) -> some View {
        let tint = connector?.health.color ?? Semantic.warning
        let label = connector?.health.title ?? "未连接"
        return HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(label)
                .font(AppFont.tiny)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, AppSpace.sm)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.11)))
    }

    private func pulseSummary(for thread: Thread) -> String {
        let live = store.state.liveActivity.trimmingCharacters(in: .whitespacesAndNewlines)
        if store.state.isGenerating && !live.isEmpty {
            return live
        }
        if let followUp = store.state.pendingFollowUp?.trimmingCharacters(in: .whitespacesAndNewlines),
           !followUp.isEmpty {
            return "已收到补充：\(followUp)"
        }
        if thread.isExecution && thread.status == .failed {
            return failedTaskSummary(for: thread)
        }
        if thread.isExecution && thread.status == .cancelled {
            return "这个会话已暂停。可以继续处理，或改写目标后再发送。"
        }
        if let latest = latestThreadSummary(thread) {
            return latest
        }
        return thread.steps.isEmpty ? "这个会话还没有内容。" : "最近内容会在这里压缩显示。"
    }

    private func fallbackAgentGoal(for thread: Thread) -> String {
        if let firstUser = thread.steps.first(where: { $0.kind == .userInput })?.text.trimmingCharacters(in: .whitespacesAndNewlines),
           !firstUser.isEmpty {
            return firstUser
        }
        return thread.title.isEmpty ? "等待用户输入目标。" : thread.title
    }

    private func inferredAgentPlan(for thread: Thread) -> [String] {
        if thread.steps.isEmpty {
            return ["等待目标", "建立上下文", "按证据推进"]
        }
        var lines: [String] = []
        if thread.steps.contains(where: { $0.kind == .toolResult && $0.isFailure }) {
            lines.append("恢复最近失败，必要时更换工具路径")
        }
        if thread.context.memory.readFiles.isEmpty {
            lines.append("补齐关键上下文和文件证据")
        } else {
            lines.append("基于已读文件继续执行")
        }
        if thread.isExecution {
            lines.append("验证结果并形成交付")
        } else {
            lines.append("回答用户并等待下一步")
        }
        return lines
    }

    private func inferredArtifacts(for thread: Thread) -> [AgentArtifact] {
        var seen: Set<String> = []
        var result: [AgentArtifact] = []
        for step in thread.steps where !step.isFailure {
            let path: String?
            let kind: String
            if step.toolName == "document.transform" {
                path = step.toolParams?["pdfPath"] ?? step.toolParams?["outputPath"]
                kind = "document"
            } else if step.toolName == "image.generate" {
                path = step.toolParams?["imagePath"]
                kind = "image"
            } else if step.kind == .reviewRequest {
                path = step.diffFilePath ?? step.toolParams?["path"]
                kind = "file"
            } else {
                path = nil
                kind = "file"
            }
            guard let path, !path.isEmpty, seen.insert(path).inserted else { continue }
            result.append(AgentArtifact(title: URL(fileURLWithPath: path).lastPathComponent, path: path, kind: kind, createdAt: step.createdAt))
        }
        return result
    }

    private func threadFacts(for thread: Thread) -> [WorkbenchContextFact] {
        var facts: [WorkbenchContextFact] = [
            .init(icon: "person.crop.circle.badge.gearshape", title: "类型", value: "线程", tint: statusTint(for: thread)),
            .init(icon: "number", title: "记录", value: "\(thread.steps.count)", tint: Brand.purple),
            .init(icon: thread.projectID == nil ? "tray" : "folder", title: "空间", value: projectLabel(for: thread), tint: thread.projectID == nil ? TextGrade.muted : Brand.teal),
            .init(icon: "clock", title: "更新", value: RelativeTimeFormatter.string(for: thread.updatedAt), tint: TextGrade.muted)
        ]
        if thread.isExecution {
            facts[1] = .init(icon: "doc.text", title: "文件", value: "\(thread.context.relevantFiles.count)", tint: Brand.teal)
        }
        if let start = store.state.generationStartedAt, store.state.isGenerating, thread.id == store.state.selectedThreadID {
            facts[3] = .init(icon: "timer", title: "用时", value: formatElapsed(Date().timeIntervalSince(start)), tint: Semantic.toolRunning)
        }
        return facts
    }

    private func projectLabel(for thread: Thread) -> String {
        if let projectID = thread.projectID,
           let project = projectManager.projects.first(where: { $0.id == projectID }) {
            return project.name
        }
        return "全局"
    }

    private var workspaceName: String {
        let name = URL(fileURLWithPath: store.state.settings.workspacePath).lastPathComponent
        return name.isEmpty ? store.state.workspaceName : name
    }

    private var activeModelTitle: String {
        guard let connector = store.state.activeConnector else { return "未连接模型" }
        return connector.modelName.isEmpty ? connector.name : connector.modelName
    }

    private var twoColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: AppSpace.sm),
            GridItem(.flexible(), spacing: AppSpace.sm)
        ]
    }

    private func compactTokenCount(_ value: Int) -> String {
        if value >= 1_000_000 {
            return "\(String(format: "%.1f", Double(value) / 1_000_000))M"
        }
        if value >= 1000 {
            return "\(value / 1000)k"
        }
        return "\(value)"
    }

    private func formatElapsed(_ value: TimeInterval) -> String {
        if value < 60 { return "\(max(1, Int(value.rounded()))) 秒" }
        if value < 3600 { return "\(Int(value / 60)) 分钟" }
        return "\(Int(value / 3600)) 小时"
    }

    private func latestThreadSummary(_ thread: Thread) -> String? {
        let slice = thread.steps.suffix(10)
        guard let text = slice.reversed().first(where: { step in
            let cleaned = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !cleaned.isEmpty && step.kind != .userInput && !isInternalSummary(cleaned)
        })?.text ?? slice.reversed().first(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.text else {
            return nil
        }
        return compactWorkbenchText(text, limit: 150)
    }

    private func failedTaskSummary(for thread: Thread) -> String {
        let failedTools = thread.steps.suffix(40).filter { $0.kind == .toolResult && $0.isFailure }.count
        if failedTools > 0 {
            return "这个会话没有完成，检测到 \(failedTools) 个工具失败。可以点“继续”沿用已读信息，或重试最近请求。"
        }
        return "这个会话没有完成，但没有检测到具体工具失败。可以点“继续”补齐下一步，或重试最近请求。"
    }

    private func compactWorkbenchText(_ text: String, limit: Int) -> String {
        let compact = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return "" }
        return compact.count > limit ? String(compact.prefix(max(0, limit - 1))) + "…" : compact
    }

    private func agentTitle(for thread: Thread) -> String {
        let trimmed = thread.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "新会话" { return "新会话" }
        return TextHelper.compactTitle(trimmed)
    }

    private func isInternalSummary(_ text: String) -> Bool {
        let prefixes = ["任务检查点", "完成检查", "阶段总结", "证据清单", "执行路径"]
        return prefixes.contains { text.hasPrefix($0) }
    }
}

private struct AgentArtifactRow: View {
    let artifact: AgentArtifact
    @State private var isHovering = false

    private var url: URL {
        URL(fileURLWithPath: artifact.path)
    }

    private var exists: Bool {
        FileManager.default.fileExists(atPath: artifact.path)
    }

    private var icon: String {
        switch artifact.kind {
        case "image": return "photo"
        case "document": return "doc.richtext"
        default: return "doc"
        }
    }

    var body: some View {
        HStack(spacing: AppSpace.xs) {
            Button {
                if exists {
                    NSWorkspace.shared.open(url)
                } else {
                    copyPath()
                }
            } label: {
                HStack(spacing: AppSpace.xs) {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(exists ? Brand.teal : TextGrade.ghost)
                        .frame(width: 14)
                    Text(artifact.title)
                        .font(AppFont.caption)
                        .foregroundStyle(exists ? TextGrade.secondary : TextGrade.ghost)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .buttonStyle(.plain)
            .help(exists ? artifact.path : "文件不存在，点击复制路径")

            Spacer(minLength: 0)

            if isHovering {
                artifactIconButton(icon: "folder", tooltip: "在 Finder 中显示") {
                    if exists {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        copyPath()
                    }
                }
                artifactIconButton(icon: "doc.on.doc", tooltip: "复制路径") {
                    copyPath()
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(AppAnimation.quick) {
                isHovering = hovering
            }
        }
        .contextMenu {
            Button {
                if exists { NSWorkspace.shared.open(url) }
            } label: {
                Label("打开", systemImage: "arrow.up.right.square")
            }
            .disabled(!exists)

            Button {
                if exists {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
            }
            .disabled(!exists)

            Button {
                copyPath()
            } label: {
                Label("复制路径", systemImage: "doc.on.doc")
            }
        }
    }

    private func artifactIconButton(icon: String, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(TextGrade.muted)
                .frame(width: 18, height: 18)
                .background(Circle().fill(SurfaceGrade.elevated.opacity(0.78)))
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    @MainActor
    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(artifact.path, forType: .string)
        ToastCenter.shared.success("已复制产物路径")
    }
}

private struct WorkbenchContextFact: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let value: String
    let tint: Color
}

private struct InspectorBlock<Content: View>: View {
    let title: String
    var trailing: AnyView?
    @ViewBuilder let content: () -> Content

    init(title: String, trailing: AnyView? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            HStack(spacing: AppSpace.sm) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TextGrade.muted)
                    .textCase(nil)
                Spacer()
                trailing
            }
            content()
        }
        .padding(AppSpace.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [SurfaceGrade.card.opacity(0.86), SurfaceGrade.elevated.opacity(0.56)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(SurfaceGrade.hairline.opacity(0.72), lineWidth: 0.7)
        )
        .shadow(color: AppShadow.sm.color.opacity(0.75), radius: AppShadow.sm.radius, y: AppShadow.sm.y)
    }
}

private struct InspectorEmptyRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: AppSpace.sm) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Brand.primary)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.captionMedium)
                    .foregroundStyle(TextGrade.secondary)
                Text(subtitle)
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.muted)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, AppSpace.xs)
    }
}

private struct InspectorDivider: View {
    var body: some View {
        Rectangle()
            .fill(SurfaceGrade.hairline.opacity(0.85))
            .frame(height: 0.5)
            .padding(.leading, 24)
    }
}

private struct InspectorMetricTile: View {
    let icon: String
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: AppSpace.sm) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .background(Circle().fill(tint.opacity(0.10)))

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(AppFont.micro)
                    .foregroundStyle(TextGrade.ghost)
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TextGrade.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpace.sm)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(SurfaceGrade.elevated.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(SurfaceGrade.hairline.opacity(0.65), lineWidth: 0.6)
        )
    }
}

private struct InspectorCommandTile: View {
    let icon: String
    let title: String
    let tint: Color
    var isEnabled = true
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpace.sm) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isEnabled ? tint : TextGrade.ghost)
                Text(title)
                    .font(AppFont.captionMedium)
                    .foregroundStyle(isEnabled ? TextGrade.secondary : TextGrade.ghost)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppSpace.sm)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .fill(isHovering && isEnabled ? tint.opacity(0.10) : SurfaceGrade.elevated.opacity(0.50))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .strokeBorder(isEnabled ? tint.opacity(isHovering ? 0.24 : 0.12) : SurfaceGrade.hairline.opacity(0.65), lineWidth: 0.7)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(title)
        .onHover { hovering in
            withAnimation(AppAnimation.quick) { isHovering = hovering }
        }
    }
}

private struct InspectorActivityLine: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: AppSpace.sm) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16, height: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.captionMedium)
                    .foregroundStyle(TextGrade.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.muted)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, AppSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WorkbenchFactTile: View {
    let fact: WorkbenchContextFact

    var body: some View {
        HStack(spacing: AppSpace.sm) {
            Image(systemName: fact.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(fact.tint)
                .frame(width: 20, height: 20)
                .background(Circle().fill(fact.tint.opacity(0.10)))
            Text(fact.title)
                .font(AppFont.micro)
                .foregroundStyle(TextGrade.ghost)
                .frame(width: 32, alignment: .leading)
            Text(fact.value)
                .font(AppFont.captionMedium)
                .foregroundStyle(TextGrade.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpace.sm)
        .padding(.vertical, AppSpace.xs + 2)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(SurfaceGrade.card.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(SurfaceGrade.hairline.opacity(0.75), lineWidth: 0.6)
        )
    }
}

private struct WorkbenchActionButton: View {
    let icon: String
    let title: String
    let tint: Color
    var isEnabled = true
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(AppFont.micro)
                    .lineLimit(1)
            }
            .foregroundStyle(isEnabled ? tint : TextGrade.ghost)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .fill(isHovering && isEnabled ? tint.opacity(0.10) : SurfaceGrade.card.opacity(0.58))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .strokeBorder(isEnabled ? tint.opacity(isHovering ? 0.24 : 0.12) : SurfaceGrade.hairline, lineWidth: 0.7)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(title)
        .onHover { hovering in
            withAnimation(AppAnimation.quick) { isHovering = hovering }
        }
    }
}

private struct ThreadContextCard: View {
    let thread: ThreadRecord
    let workspaceRoot: String
    let contextMode: ContextMode
    let connector: ConnectorProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.sm) {
            Text("运行信息")
                .font(AppFont.captionMedium)
                .foregroundStyle(TextGrade.secondary)

            contextRow(icon: "folder", label: "工作区", value: workspaceRoot)
                contextRow(icon: "doc.text", label: "文件", value: "\(workspaceRoot.isEmpty ? 0 : thread.events.count) 项")
                contextRow(icon: "bubble.left.and.bubble.right", label: "记录", value: "\(thread.events.count) 条")
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 16, height: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: AppSpace.xs) {
                    Text(activity.summary.isEmpty ? activity.name : activity.summary)
                        .font(AppFont.captionMedium)
                        .foregroundStyle(TextGrade.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

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

                Text(activity.name)
                    .font(AppFont.codeSmall)
                    .foregroundStyle(TextGrade.ghost)
                    .lineLimit(1)
                    .opacity(activity.name.isEmpty || activity.name == activity.summary ? 0 : 1)
            }
        }
        .padding(.vertical, AppSpace.sm)
        .padding(.horizontal, AppSpace.xs)
    }

    private var statusColor: Color {
        activity.isFailure ? Semantic.error : Semantic.success
    }
}
