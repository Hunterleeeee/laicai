import AppKit
import SwiftUI
import LaicaiNativeDomain
import LaicaiNativeFoundation

public typealias Thread = LaicaiThread

// MARK: - Toolbar Button

struct ToolbarButton: View {
    let icon: String
    var tooltip: String = ""
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? TextGrade.primary : TextGrade.muted)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                        .fill(isHovered ? SurfaceGrade.hover : SurfaceGrade.elevated.opacity(0.72))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                        .strokeBorder(isHovered ? SurfaceGrade.border.opacity(0.8) : SurfaceGrade.hairline, lineWidth: 0.6)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(AppAnimation.micro) { isHovered = h } }
        .help(tooltip)
    }
}

struct MenuIconLabel: View {
    let icon: String
    var tooltip: String = ""

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(TextGrade.muted)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .help(tooltip)
    }
}

// MARK: - Task Stream View

struct ThreadTimelineView: View {
    @EnvironmentObject private var store: AppStore
    let thread: Thread
    private let bottomID = "thread-bottom-anchor"
    private let compactStepLimit = 12
    private let runningStepLimit = 8
    private let heavyStepLimit = 4
    private let heavyThreadThreshold = 80
    @State private var scrollToken = 0
    @State private var showFullHistory = false
    @State private var userScrolledAway = false
    @State private var expandedPhases: Set<String> = []

    var body: some View {
        let executionSteps = thread.isExecutionAgent ? visibleSteps(for: thread) : []
        let executionStats = thread.isExecutionAgent ? TaskStepStats(thread: thread, visibleSteps: executionSteps) : nil
        let sessionSteps = thread.isExecutionAgent ? [] : visibleSessionSteps
        let showsEmptyRunningState = thread.steps.isEmpty

        return ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppSpace.xl) {
                        if thread.isExecutionAgent, let executionStats {
                            TaskSummaryCard(thread: thread, stats: executionStats)
                            if thread.status == .completed || thread.status == .failed {
                                TaskCompletionSummaryCard(thread: thread)
                                TaskRatingBar(threadID: thread.id, currentRating: store.state.threads.first(where: { $0.id == thread.id })?.userRating ?? 0)
                            }
                            if let plan = thread.multiAgentPlan {
                                if plan.isEditable {
                                    MultiAgentPlanEditorView(
                                        plan: Binding(
                                            get: { plan },
                                            set: { newPlan in
                                                store.updateMultiAgentPlan(newPlan, for: thread.id)
                                            }
                                        ),
                                        connectors: store.state.connectors,
                                        workspaceRoot: store.state.settings.workspacePath,
                                        onExecute: {
                                            store.executeEditedPlan(threadID: thread.id)
                                        },
                                        onCancel: {
                                            store.cancelMultiAgentPlan(for: thread.id)
                                        }
                                    )
                                } else {
                                    MultiAgentFlowView(plan: plan)
                                    ResumePlanButton(plan: plan) {
                                        store.resumeFailedPlan(threadID: thread.id)
                                }
                            }
                        }
                        if showsEmptyRunningState {
                            EmptyRunningThreadCard(thread: thread)
                        }
                        if shouldCompact(thread) {
                            TaskHistoryFoldCard(
                                hiddenCount: hiddenStepCount(thread),
                                showFullHistory: $showFullHistory
                            )
                        }
                        ForEach(phaseGroups(for: executionSteps)) { group in
                            if group.isToolPhase {
                                PhaseGroupCard(
                                    group: group,
                                    taskID: thread.id,
                                    isRunning: thread.status == .running,
                                    isCollapsed: !expandedPhases.contains(group.id),
                                    onToggle: {
                                        if expandedPhases.contains(group.id) {
                                            expandedPhases.remove(group.id)
                                        } else {
                                            expandedPhases.insert(group.id)
                                        }
                                    }
                                )
                            } else {
                                ForEach(group.steps) { step in
                                    TaskStepCard(
                                        step: step,
                                        taskID: thread.id,
                                        isRunning: thread.status == .running
                                    )
                                    .id(step.id)
                                }
                            }
                        }
                    } else {
                        if shouldCompact(thread) {
                            TaskHistoryFoldCard(
                                hiddenCount: hiddenStepCount(thread),
                                showFullHistory: $showFullHistory
                            )
                        }
                        ForEach(sessionSteps) { step in
                            SessionStepCard(step: step)
                                .id(step.id)
                        }
                    }

                    if store.state.isGenerating {
                        TypingIndicator()
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .frame(maxWidth: LayoutConst.conversationMaxWidth, alignment: .leading)
                .padding(.horizontal, AppSpace.xxl)
                .padding(.top, AppSpace.xxl)
                .padding(.bottom, AppSpace.xl)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .coordinateSpace(name: "timeline-scroll")
            .background(SurfaceGrade.base)
            .onAppear {
                scrollToBottom(proxy)
            }
            .onChange(of: thread.steps.count) { _ in scheduleScrollToBottom(proxy) }
            .onChange(of: store.state.isGenerating) { isGen in
                if isGen { userScrolledAway = false; scheduleScrollToBottom(proxy) }
            }
            .onChange(of: thread.status) { newStatus in
                if newStatus == .running { userScrolledAway = false; scheduleScrollToBottom(proxy) }
            }
            .onChange(of: streamingTextLength) { _ in scheduleScrollToBottom(proxy) }
            .onReceive(NotificationCenter.default.publisher(for: .laicaiPanelToggled)) { _ in
                userScrolledAway = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !userScrolledAway else { return }
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .laicaiScrollToBottom)) { _ in
                userScrolledAway = false
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
                // Batch review floating bar
                if let executionStats {
                    if executionStats.pendingReviewIDs.count >= 2 {
                        BatchReviewBar(
                            pendingCount: executionStats.pendingReviewIDs.count,
                            taskID: thread.id,
                            stepIDs: executionStats.pendingReviewIDs
                        )
                        .padding(.bottom, AppSpace.xl)
                        .padding(.trailing, AppSpace.xxl)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }

                // Scroll-to-bottom floating button
                if userScrolledAway {
                    Button {
                        userScrolledAway = false
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    } label: {
                        ZStack {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(TextGrade.inverted)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(Brand.primary)
                                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, AppSpace.xl)
                    .padding(.trailing, AppSpace.xxl)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func scheduleScrollToBottom(_ proxy: ScrollViewProxy) {
        guard !userScrolledAway else { return }
        scrollToken += 1
        let token = scrollToken
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard token == scrollToken else { return }
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }

    /// Tracks total text length of the last step — when streaming appends text
    /// to an existing step, steps.count doesn't change but this does, triggering auto-scroll.
    /// Quantized to ~200 chars to avoid firing on every single character append.
    private var streamingTextLength: Int {
        let raw: Int
        raw = thread.steps.last?.text.count ?? 0
        return raw / 200
    }

    private func shouldCompact(_ thread: Thread) -> Bool {
        !showFullHistory && thread.steps.count > stepLimit(for: thread)
    }

    private func hiddenStepCount(_ thread: Thread) -> Int {
        max(thread.steps.count - stepLimit(for: thread), 0)
    }

    private func visibleSteps(for thread: Thread) -> [TaskStep] {
        let limit = stepLimit(for: thread)
        let steps = (!showFullHistory && thread.steps.count > limit) ? Array(thread.steps.suffix(limit)) : thread.steps
        // Merge continuation textOutput steps into their originals
        let continuations = steps.filter { $0.continuationOf != nil && $0.kind == .textOutput }
        guard !continuations.isEmpty else { return steps }
        var merged = steps.filter { $0.continuationOf == nil || $0.kind != .textOutput }
        for cont in continuations {
            if let idx = merged.firstIndex(where: { $0.id == cont.continuationOf }) {
                var step = merged[idx]
                step.text += "\n" + cont.text
                step.metrics = cont.metrics ?? step.metrics
                step.continuationOf = nil
                merged[idx] = step
            } else {
                merged.append(cont)
            }
        }
        return merged
    }

    private func stepLimit(for thread: Thread) -> Int {
        if thread.steps.count > heavyThreadThreshold { return heavyStepLimit }
        return thread.status == .running ? runningStepLimit : compactStepLimit
    }

    private var visibleSessionSteps: [TaskStep] {
        let limit = thread.status == .running ? runningStepLimit : compactStepLimit
        return (!showFullHistory && thread.steps.count > limit) ? Array(thread.steps.suffix(limit)) : thread.steps
    }
}

private struct EmptyRunningThreadCard: View {
    let thread: Thread

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            HStack(spacing: AppSpace.md) {
                ZStack {
                    Circle()
                        .fill(Semantic.toolRunning.opacity(0.12))
                        .frame(width: 30, height: 30)
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.72)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(TextHelper.compactTitle(thread.title))
                        .font(AppFont.headline)
                        .foregroundStyle(TextGrade.primary)
                        .lineLimit(2)
                    Text(statusLine)
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                }
            }

            if let goal = visibleGoal {
                Text(goal)
                    .font(AppFont.body)
                    .foregroundStyle(TextGrade.secondary)
                    .lineLimit(3)
            }
        }
        .padding(AppSpace.lg)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .fill(SurfaceGrade.card.opacity(0.84))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(Semantic.toolRunning.opacity(0.20), lineWidth: 0.7)
        )
    }

    private var statusLine: String {
        if thread.multiAgentPlan != nil { return "多会话计划已创建，正在启动第一步…" }
        if thread.status == .running || thread.agentState == .running { return "会话已创建，正在准备上下文…" }
        return "正在准备…"
    }

    private var visibleGoal: String? {
        let raw = thread.agentGoal?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? thread.executionLedger?.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }
}

private struct TaskHistoryFoldCard: View {
    let hiddenCount: Int
    @Binding var showFullHistory: Bool

    var body: some View {
        HStack(alignment: .center, spacing: AppSpace.sm) {
            Image(systemName: "rectangle.compress.vertical")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(TextGrade.muted)
                .frame(width: 22, height: 22)
                .background(Circle().fill(SurfaceGrade.sunken.opacity(0.72)))

            VStack(alignment: .leading, spacing: 2) {
                Text("已折叠 \(hiddenCount) 条早期步骤")
                    .font(AppFont.captionMedium)
                    .foregroundStyle(TextGrade.secondary)
                Text("保留最近进展，完整历史仍在本地。")
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
            }

            Spacer()

            Button {
                showFullHistory = true
            } label: {
                Text("展开")
                    .font(AppFont.captionMedium)
                    .foregroundStyle(Brand.primary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AppSpace.md)
        .padding(.vertical, AppSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(SurfaceGrade.elevated.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(SurfaceGrade.hairline.opacity(0.8), lineWidth: 0.6)
        )
    }
}

private struct ThreadSummaryCard: View {
    let thread: ThreadRecord

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.sm) {
            HStack(spacing: AppSpace.sm) {
                Image(systemName: thread.isPinned ? "pin.fill" : agentIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(thread.isPinned ? Semantic.warning : agentTint)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill((thread.isPinned ? Semantic.warning : agentTint).opacity(0.12)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.title)
                        .font(AppFont.headline)
                        .foregroundStyle(TextGrade.primary)
                        .lineLimit(2)
                    Text("会话 · \(thread.resolvedAgentState.title) · \(thread.events.count) 条记录 · \(RelativeTimeFormatter.string(for: thread.updatedAt))")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                }

                Spacer()
            }

            if !thread.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(thread.preview)
                    .font(AppFont.body)
                    .foregroundStyle(TextGrade.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(AppSpace.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                            .fill(SurfaceGrade.panel.opacity(0.75))
                    )
            }
        }
        .padding(AppSpace.lg)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(SurfaceGrade.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(SurfaceGrade.divider, lineWidth: 0.75)
        )
    }

    private var agentIcon: String {
        switch thread.resolvedAgentState {
        case .planning: return "list.bullet.clipboard"
        case .running: return "waveform.path.ecg"
        case .waitingForApproval: return "hand.raised.fill"
        case .blocked, .failed: return "exclamationmark.triangle.fill"
        case .paused: return "pause.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .archived: return "archivebox.fill"
        case .idle: return thread.hasContent ? "bubble.left.and.bubble.right.fill" : "sparkles"
        }
    }

    private var agentTint: Color {
        switch thread.resolvedAgentState {
        case .planning, .running: return Brand.primary
        case .waitingForApproval: return Semantic.warning
        case .blocked, .failed: return Semantic.error
        case .paused: return TextGrade.muted
        case .completed: return Semantic.success
        case .archived: return TextGrade.ghost
        case .idle: return Brand.primary
        }
    }
}

private struct SessionStepCard: View {
    let step: TaskStep

    var body: some View {
        switch step.kind {
        case .userInput:
            UserInputCard(text: step.text)
        case .textOutput:
            TextOutputCard(text: step.text, metrics: step.metrics, isRunning: step.metrics == nil && step.toolCallId == AppStore.streamingOutputID)
        case .aiThinking:
            ThinkingCard(text: step.text, reasoningContent: step.reasoningContent, isRunning: false)
        case .toolCall:
            timelineSystemCard(icon: "wrench.and.screwdriver.fill", title: "工具调用", text: step.text, color: Semantic.toolCall)
        case .toolResult:
            timelineSystemCard(icon: "checkmark.circle.fill", title: "工具结果", text: step.text, color: step.isFailure ? Semantic.error : Semantic.success)
        case .reviewRequest:
            timelineSystemCard(icon: "eye.fill", title: "审查", text: step.text, color: Semantic.warning)
        case .reviewResult:
            timelineSystemCard(icon: "checkmark.seal.fill", title: "审查结果", text: step.text, color: Semantic.success)
        case .error:
            timelineSystemCard(icon: "exclamationmark.triangle.fill", title: "错误", text: step.text, color: Semantic.error)
        }
    }

    private func timelineSystemCard(icon: String, title: String, text: String, color: Color) -> some View {
        let display = text.count > 800 ? String(text.prefix(800)) + "\n\n… 共 \(text.count) 字，已折叠" : text
        return HStack(alignment: .top, spacing: AppSpace.sm) {
            AvatarBadge(icon: icon, color: color)

            VStack(alignment: .leading, spacing: AppSpace.xs) {
                Text(title)
                    .font(AppFont.captionMedium)
                    .foregroundStyle(color)

                Text(display)
                    .font(AppFont.body)
                    .foregroundStyle(TextGrade.secondary)
                    .lineLimit(8)
                    .padding(AppSpace.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                            .fill(SurfaceGrade.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                            .strokeBorder(color.opacity(0.18), lineWidth: 1)
                    )
            }

            Spacer()
        }
    }
}

// MARK: - Multi-Agent Flow View

struct MultiAgentFlowView: View {
    let plan: MultiAgentPlan
    @State private var selectedAgentID: UUID?
    @State private var pulsePhase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ──
            HStack(spacing: AppSpace.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                        .fill(Brand.purple.opacity(0.12))
                        .frame(width: 30, height: 30)
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Brand.purple)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("多会话协同编排")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TextGrade.primary)
                    Text("\(plan.agents.count) 个会话 · \(plan.progress)")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                }

                Spacer()

                flowStatusPill(for: plan.status)
            }
            .padding(.horizontal, AppSpace.xl)
            .padding(.vertical, AppSpace.lg)

            // ── Divider ──
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.clear, Brand.purple.opacity(0.15), Color.clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 0.5)

            // ── Flow Pipeline ──
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(plan.agents.enumerated()), id: \.element.id) { index, agent in
                        flowNodeCard(agent: agent, index: index)
                            .onTapGesture {
                                selectedAgentID = selectedAgentID == agent.id ? nil : agent.id
                            }

                        if index < plan.agents.count - 1 {
                            flowConnector(from: agent, toIndex: index + 1)
                        }
                    }
                }
                .padding(.horizontal, AppSpace.xl)
                .padding(.vertical, AppSpace.xl)
            }

            // ── Selected Agent Detail ──
            if let selectedID = selectedAgentID,
               let agent = plan.agents.first(where: { $0.id == selectedID }) {
                Rectangle().fill(SurfaceGrade.divider).frame(height: 0.5)
                flowAgentDetail(agent: agent)
                    .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .fill(SurfaceGrade.card.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Brand.purple.opacity(0.20), Brand.primary.opacity(0.10), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
        .shadow(color: Brand.purple.opacity(0.035), radius: 6, y: 2)
        .onAppear { pulsePhase = true }
    }

    // ── Node Card ──

    private func flowNodeCard(agent: AgentNode, index: Int) -> some View {
        let isSelected = selectedAgentID == agent.id
        let isRunning = agent.status == .running
        let nodeColor = flowColor(for: agent.status)

        return VStack(spacing: AppSpace.sm) {
            ZStack {
                // Background circle
                Circle()
                    .fill(nodeColor.opacity(0.10))
                    .frame(width: 52, height: 52)

                if isRunning {
                    Circle()
                        .stroke(nodeColor.opacity(0.35), lineWidth: 2)
                        .frame(width: 52, height: 52)
                }

                // Completed checkmark ring
                if agent.status == .completed {
                    Circle()
                        .stroke(nodeColor.opacity(0.25), lineWidth: 2)
                        .frame(width: 52, height: 52)
                }

                // Selected ring
                if isSelected && !isRunning {
                    Circle()
                        .stroke(nodeColor.opacity(0.35), lineWidth: 1.5)
                        .frame(width: 56, height: 56)
                }

                // Icon
                Image(systemName: agent.role.icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(nodeColor)
            }

            // Label
            VStack(spacing: 2) {
                Text(agent.role.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? TextGrade.primary : TextGrade.secondary)

                flowStatusLabel(agent.status)
            }

            // Step count
            if !agent.stepIDs.isEmpty {
                Text("\(agent.stepIDs.count) 步")
                    .font(AppFont.micro)
                    .foregroundStyle(TextGrade.ghost)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(SurfaceGrade.elevated.opacity(0.6))
                    )
            }
        }
        .frame(minWidth: 80)
        .padding(.vertical, AppSpace.sm)
        .padding(.horizontal, AppSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .fill(isSelected ? SurfaceGrade.elevated.opacity(0.5) : Color.clear)
        )
    }

    // ── Connector ──

    private func flowConnector(from agent: AgentNode, toIndex: Int) -> some View {
        let handoff = plan.handoffs.first(where: {
            $0.fromAgentID == agent.id && toIndex < plan.agents.count && $0.toAgentID == plan.agents[toIndex].id
        })
        let hasArtifact = !(handoff?.artifact.isEmpty ?? true)
        let isDone = agent.status == .completed
        let isActive = agent.status == .running

        return VStack(spacing: AppSpace.xs) {
            ZStack {
                // Connector line
                RoundedRectangle(cornerRadius: 1)
                    .fill(
                        isDone
                        ? LinearGradient(colors: [flowColor(for: .completed).opacity(0.5), flowColor(for: .completed).opacity(0.2)], startPoint: .leading, endPoint: .trailing)
                        : LinearGradient(colors: [TextGrade.ghost.opacity(0.3), TextGrade.ghost.opacity(0.15)], startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: 32, height: 2)

                if isActive {
                    Circle()
                        .fill(Brand.primary)
                        .frame(width: 6, height: 6)
                }

                // Arrow head
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isDone ? flowColor(for: .completed).opacity(0.6) : TextGrade.ghost.opacity(0.4))
                    .offset(x: 20)
            }
            .frame(width: 48)

            if hasArtifact {
                Text("数据")
                    .font(AppFont.micro)
                    .foregroundStyle(Brand.primary.opacity(0.7))
            }
        }
    }

    // ── Agent Detail Panel ──

    private func flowAgentDetail(agent: AgentNode) -> some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            HStack(spacing: AppSpace.md) {
                ZStack {
                    Circle()
                        .fill(flowColor(for: agent.status).opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: agent.role.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(flowColor(for: agent.status))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.role.title)
                        .font(AppFont.headline)
                        .foregroundStyle(TextGrade.primary)
                    Text(agent.status.title)
                        .font(AppFont.caption)
                        .foregroundStyle(flowColor(for: agent.status))
                }

                Spacer()

                if !agent.output.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                        Text("已产出")
                            .font(AppFont.captionMedium)
                    }
                    .foregroundStyle(Semantic.success)
                }
            }

            if !agent.input.isEmpty {
                VStack(alignment: .leading, spacing: AppSpace.xs) {
                    Label("输入", systemImage: "arrow.down.circle")
                        .font(AppFont.micro)
                        .foregroundStyle(TextGrade.ghost)
                    Text(agent.input)
                        .font(AppFont.body)
                        .foregroundStyle(TextGrade.secondary)
                        .lineLimit(4)
                        .padding(AppSpace.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                                .fill(SurfaceGrade.sunken)
                        )
                }
            }

            if !agent.output.isEmpty {
                VStack(alignment: .leading, spacing: AppSpace.xs) {
                    Label("输出", systemImage: "arrow.up.circle")
                        .font(AppFont.micro)
                        .foregroundStyle(TextGrade.ghost)
                    Text(agent.output)
                        .font(AppFont.body)
                        .foregroundStyle(TextGrade.secondary)
                        .lineLimit(6)
                        .textSelection(.enabled)
                        .padding(AppSpace.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                                .fill(SurfaceGrade.sunken)
                        )
                }
            }

            if !agent.stepIDs.isEmpty {
                HStack(spacing: AppSpace.xs) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 10))
                    Text("\(agent.stepIDs.count) 个执行步骤")
                        .font(AppFont.caption)
                }
                .foregroundStyle(TextGrade.muted)
            }
        }
        .padding(AppSpace.xl)
    }

    // ── Helpers ──

    private func flowStatusLabel(_ status: TaskStatus) -> some View {
        Text(status.title)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(flowColor(for: status))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(flowColor(for: status).opacity(0.10))
            )
    }

    private func flowStatusPill(for status: TaskStatus) -> some View {
        HStack(spacing: 4) {
            if status == .running {
                Circle()
                    .fill(flowColor(for: status))
                    .frame(width: 6, height: 6)
            } else {
                Circle()
                    .fill(flowColor(for: status))
                    .frame(width: 6, height: 6)
            }
            Text(status.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(flowColor(for: status))
        }
        .padding(.horizontal, AppSpace.sm + 2)
        .padding(.vertical, AppSpace.xs + 1)
        .background(
            Capsule().fill(flowColor(for: status).opacity(0.10))
        )
        .overlay(
            Capsule().strokeBorder(flowColor(for: status).opacity(0.15), lineWidth: 0.5)
        )
    }

    private func flowColor(for status: TaskStatus) -> Color {
        switch status {
        case .queued: return TextGrade.muted
        case .running: return Brand.primary
        case .waitingReview: return Semantic.warning
        case .completed: return Semantic.success
        case .failed: return Semantic.error
        case .cancelled: return TextGrade.ghost
        }
    }
}

// MARK: - Phase Grouping

struct StepPhaseGroup: Identifiable {
    let id: String
    let phase: TaskPhase
    let steps: [TaskStep]
    var isToolPhase: Bool { steps.allSatisfy { $0.kind == .toolCall || $0.kind == .toolResult } }
}

private func phaseGroups(for steps: [TaskStep]) -> [StepPhaseGroup] {
    var groups: [StepPhaseGroup] = []
    var currentNonTool: [TaskStep] = []

    func flushNonTool() {
        guard !currentNonTool.isEmpty else { return }
        let anchor = currentNonTool[0].id.uuidString
        groups.append(StepPhaseGroup(id: "nontool-\(anchor)", phase: .explore, steps: currentNonTool))
        currentNonTool = []
    }

    var i = 0
    while i < steps.count {
        let step = steps[i]
        if step.kind == .toolCall || step.kind == .toolResult {
            flushNonTool()
            var toolSteps: [TaskStep] = []
            while i < steps.count && (steps[i].kind == .toolCall || steps[i].kind == .toolResult) {
                toolSteps.append(steps[i])
                i += 1
            }
            let anchor = toolSteps[0].id.uuidString
            let phase = AgentLoop.inferPhase(from: toolSteps)
            groups.append(StepPhaseGroup(id: "tool-\(anchor)", phase: phase, steps: toolSteps))
        } else {
            currentNonTool.append(step)
            i += 1
        }
    }
    flushNonTool()
    return groups
}

struct PhaseGroupCard: View {
    let group: StepPhaseGroup
    let taskID: UUID
    let isRunning: Bool
    let isCollapsed: Bool
    let onToggle: () -> Void

    private var toolCallCount: Int {
        group.steps.filter { $0.kind == .toolCall }.count
    }
    private var failureCount: Int {
        group.steps.filter { $0.isFailure }.count
    }
    private var toolNames: [String] {
        Array(Set(group.steps.compactMap { $0.toolName }).filter { $0 != "workspace.index" }).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: AppSpace.sm) {
                    Image(systemName: group.phase.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Brand.primary)
                    Text(group.phase.title)
                        .font(AppFont.captionMedium)
                        .foregroundStyle(TextGrade.secondary)
                    Text("\(toolCallCount) 步")
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.muted)
                    if !toolNames.isEmpty {
                        Text(toolNames.joined(separator: " · "))
                            .font(AppFont.tiny)
                            .foregroundStyle(TextGrade.ghost)
                            .lineLimit(1)
                    }
                    if failureCount > 0 {
                        Text("失败 \(failureCount) 项")
                            .font(AppFont.tiny)
                            .foregroundStyle(Semantic.error)
                    }
                    Spacer()
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(TextGrade.ghost)
                }
                .padding(.horizontal, AppSpace.md)
                .padding(.vertical, AppSpace.sm)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                        .fill(SurfaceGrade.card.opacity(0.55))
                )
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                VStack(alignment: .leading, spacing: AppSpace.sm) {
                    ForEach(group.steps) { step in
                        TaskStepCard(step: step, taskID: taskID, isRunning: isRunning)
                            .id(step.id)
                    }
                }
                .padding(.leading, AppSpace.xl)
                .padding(.top, AppSpace.xs)
            }
        }
    }
}

private struct TaskStepStats {
    let completedSteps: Int
    let failureCount: Int
    let recoveryCount: Int
    let recoverySuccessCount: Int
    let readCount: Int
    let pendingReviewIDs: [UUID]
    let currentPhase: TaskPhase
    let phaseCounts: [TaskPhase: Int]
    let phaseTools: [TaskPhase: [String]]
    let memoryPills: [String]

    init(thread: Thread, visibleSteps: [TaskStep]) {
        let steps = visibleSteps
        var completedSteps = 0
        var failureCount = 0
        var recoveryCount = 0
        var recoverySuccessCount = 0
        var readCount = 0
        var pendingReviewIDs: [UUID] = []
        var phaseCounts: [TaskPhase: Int] = [:]
        var phaseToolSets: [TaskPhase: Set<String>] = [:]

        var readFiles: [String] = []
        var seenReadFiles: Set<String> = []
        var hasWorkspaceIndex = false
        var failedToolCounts: [String: Int] = [:]
        var searches: [String] = []
        var seenSearches: Set<String> = []

        var hasFileChange = false
        var hasVerifyCheck = false
        var successfulReadCount = 0
        var searchCount = 0

        func addPhase(_ phase: TaskPhase, toolName: String? = nil) {
            phaseCounts[phase, default: 0] += 1
            guard let toolName, !toolName.isEmpty else { return }
            phaseToolSets[phase, default: []].insert(ToolNameCodec.canonicalName(toolName))
        }

        for step in steps {
            let toolName = step.toolName.map(ToolNameCodec.canonicalName)

            if step.kind != .userInput {
                completedSteps += 1
            }
            if step.isFailure || step.kind == .error {
                failureCount += 1
            }

            let isRecovery = (step.toolCallId ?? "").hasPrefix("call_recovery_") || step.text.hasPrefix("自动恢复")
            if isRecovery {
                recoveryCount += 1
                if !step.isFailure && step.kind == .toolResult {
                    recoverySuccessCount += 1
                }
            }

            if step.kind == .reviewRequest && step.approved == nil {
                pendingReviewIDs.append(step.id)
            }

            if let toolName {
                if ["workspace.index", "file.read", "code.search", "git"].contains(toolName),
                   step.kind == .toolCall || step.kind == .toolResult {
                    addPhase(.explore, toolName: toolName)
                }

                if step.kind == .toolCall,
                   ["file.write", "file.edit", "diff.apply", "shell.exec"].contains(toolName) {
                    addPhase(.execute, toolName: toolName)
                }

                if step.kind == .toolCall, toolName == "verify.build" {
                    addPhase(.verify, toolName: toolName)
                }

                if step.kind == .toolCall,
                   toolName == "shell.exec",
                   step.toolParams?["command"]?.contains("test") == true {
                    addPhase(.verify, toolName: toolName)
                }

                if ["file.write", "file.edit", "diff.apply"].contains(toolName)
                    || Self.isSuccessfulDocumentTransform(step, canonicalToolName: toolName) {
                    hasFileChange = true
                }

                if step.kind == .toolResult, toolName == "file.read", !step.isFailure {
                    readCount += 1
                    successfulReadCount += 1
                    if let path = step.toolParams?["path"] {
                        Self.appendUnique(path, to: &readFiles, seen: &seenReadFiles)
                    }
                }

                if step.kind == .toolResult, toolName == "workspace.index", !step.isFailure {
                    hasWorkspaceIndex = true
                }

                if step.kind == .toolResult, step.isFailure {
                    failedToolCounts[toolName, default: 0] += 1
                }

                if step.kind == .toolCall, toolName == "code.search" {
                    searchCount += 1
                    if let query = step.toolParams?["query"] {
                        Self.appendUnique(query, to: &searches, seen: &seenSearches)
                    }
                }
            }

            if step.kind == .reviewRequest {
                addPhase(.execute)
            }
            if step.kind == .aiThinking, step.text.hasPrefix("完成检查") {
                hasVerifyCheck = true
                addPhase(.verify)
            }
            if step.kind == .textOutput || (step.kind == .aiThinking && step.text.hasPrefix("阶段总结")) {
                addPhase(.summarize)
            }
        }

        let currentPhase: TaskPhase
        if steps.last?.kind == .textOutput && hasVerifyCheck {
            currentPhase = .summarize
        } else if hasVerifyCheck || hasFileChange {
            currentPhase = .verify
        } else if successfulReadCount + searchCount >= 3 {
            currentPhase = .execute
        } else {
            currentPhase = .explore
        }

        var memoryPills: [String] = []
        if let first = readFiles.first {
            let extra = readFiles.count > 1 ? " +\(readFiles.count - 1)" : ""
            memoryPills.append("已读 \(Self.shortPath(first))\(extra)")
        }
        if hasWorkspaceIndex {
            memoryPills.append("已有索引")
        }
        if let firstFailure = failedToolCounts
            .map({ "\($0.key) ×\($0.value)" })
            .sorted()
            .first {
            memoryPills.append("失败 \(firstFailure)")
        }
        if let firstSearch = searches.first {
            memoryPills.append("搜过 \(String(firstSearch.prefix(18)))")
        }
        if recoveryCount > 0 {
            memoryPills.append("自动恢复 ×\(recoveryCount)")
        }

        self.completedSteps = completedSteps
        self.failureCount = failureCount
        self.recoveryCount = recoveryCount
        self.recoverySuccessCount = recoverySuccessCount
        self.readCount = readCount
        self.pendingReviewIDs = pendingReviewIDs
        self.currentPhase = currentPhase
        self.phaseCounts = phaseCounts
        self.phaseTools = phaseToolSets.mapValues { $0.sorted() }
        self.memoryPills = memoryPills
    }

    func tools(for phase: TaskPhase) -> [String] {
        phaseTools[phase] ?? []
    }

    private static func appendUnique(_ value: String, to values: inout [String], seen: inout Set<String>) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !seen.contains(trimmed) else { return }
        seen.insert(trimmed)
        values.append(trimmed)
    }

    private static func isSuccessfulDocumentTransform(_ step: TaskStep, canonicalToolName: String) -> Bool {
        guard step.kind == .toolResult,
              canonicalToolName == "document.transform",
              !step.isFailure else { return false }
        let action = step.toolParams?["action"] ?? ""
        guard ["apply", "copy", "render"].contains(action) else { return false }
        let path: String?
        if action == "render" {
            path = step.toolParams?["pdfPath"] ?? step.toolParams?["outputPath"] ?? step.toolParams?["path"]
        } else {
            path = step.toolParams?["outputPath"] ?? step.toolParams?["path"]
        }
        return path?.isEmpty == false
    }

    private static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        if parts.count <= 2 { return path }
        return parts.suffix(2).joined(separator: "/")
    }
}

private struct TaskSummaryCard: View {
    let thread: Thread
    let stats: TaskStepStats

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            HStack(alignment: .center, spacing: AppSpace.md) {
                ZStack {
                    Circle()
                        .fill(thread.status.color.opacity(0.10))
                        .frame(width: 28, height: 28)
                    Image(systemName: thread.status.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(thread.status.color)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(TextHelper.compactTitle(thread.title))
                        .font(AppFont.headline)
                        .foregroundStyle(TextGrade.primary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(summaryLine)
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                    if !stats.memoryPills.isEmpty {
                        HStack(spacing: AppSpace.xs) {
                            ForEach(stats.memoryPills.prefix(3), id: \.self) { pill in
                                Text(pill)
                                    .font(AppFont.tiny)
                                    .foregroundStyle(TextGrade.secondary)
                                    .lineLimit(1)
                                    .padding(.horizontal, AppSpace.sm)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule()
                                            .fill(SurfaceGrade.sunken.opacity(0.72))
                                    )
                            }
                        }
                        .padding(.top, 2)
                    }
                }

                Spacer()
            }

            phaseProgressBar
        }
        .padding(AppSpace.lg)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .fill(SurfaceGrade.card.opacity(0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [thread.status.color.opacity(0.18), thread.status.color.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
        .shadow(color: .black.opacity(0.035), radius: 3, y: 1)
    }

    private var currentPhase: TaskPhase {
        stats.currentPhase
    }

    private var phaseProgressBar: some View {
        let phases: [TaskPhase] = [.explore, .execute, .verify, .summarize]
        let currentIndex = phases.firstIndex(of: currentPhase) ?? 0
        let isRunning = thread.status == .running

        return VStack(alignment: .leading, spacing: AppSpace.xs) {
            // Phase indicator row
            HStack(spacing: 2) {
                ForEach(Array(phases.enumerated()), id: \.offset) { index, phase in
                    let stepCount = stats.phaseCounts[phase] ?? 0
                    let tools = stats.tools(for: phase)
                    let isDone = index < currentIndex || (!isRunning && index <= currentIndex)

                    VStack(spacing: 2) {
                        HStack(spacing: AppSpace.xs) {
                            Image(systemName: isDone ? "checkmark.circle.fill" : phase.icon)
                                .font(.system(size: 8, weight: .semibold))
                            Text(phase.title)
                                .font(AppFont.tiny)
                            if stepCount > 0 {
                                Text("\(stepCount)")
                                    .font(.system(size: 7, weight: .medium))
                                    .foregroundStyle(TextGrade.ghost)
                            }
                        }
                        .foregroundStyle(index <= currentIndex ? Brand.primary : TextGrade.ghost)
                        .padding(.horizontal, AppSpace.sm)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                                .fill(index <= currentIndex ? Brand.primary.opacity(0.12) : Color.clear)
                        )
                        .help(phaseTooltip(phase, stepCount: stepCount, tools: tools))

                        // Tool mini-badges
                        if stepCount > 0 && !tools.isEmpty {
                            HStack(spacing: 2) {
                                ForEach(tools.prefix(3), id: \.self) { tool in
                                    Text(shortToolName(tool))
                                        .font(.system(size: 7))
                                        .foregroundStyle(TextGrade.ghost)
                                        .padding(.horizontal, 3)
                                        .padding(.vertical, 1)
                                        .background(
                                            Capsule().fill(SurfaceGrade.sunken.opacity(0.5))
                                        )
                                }
                            }
                        }
                    }
                }
            }

            // Overall progress bar
            GeometryReader { geo in
                let progress = Double(currentIndex + 1) / Double(phases.count)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(SurfaceGrade.sunken.opacity(0.4))
                        .frame(height: 3)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Brand.primary.opacity(0.6))
                        .frame(width: geo.size.width * CGFloat(isRunning ? progress - 0.05 : progress), height: 3)
                }
            }
            .frame(height: 3)
        }
    }

    private func shortToolName(_ name: String) -> String {
        switch name {
        case "workspace.index": return "索引"
        case "file.read": return "读取"
        case "code.search": return "搜索"
        case "file.write": return "写入"
        case "file.edit": return "编辑"
        case "diff.apply": return "补丁"
        case "shell.exec": return "命令"
        case "verify.build": return "验证"
        case "git": return "Git"
        default: return String(name.prefix(4))
        }
    }

    private func phaseTooltip(_ phase: TaskPhase, stepCount: Int, tools: [String]) -> String {
        if stepCount == 0 { return "\(phase.title)阶段：暂无步骤" }
        return "\(phase.title)阶段：\(stepCount) 步" + (tools.isEmpty ? "" : "（\(tools.joined(separator: "、"))）")
    }

    private var summaryLine: String {
        var parts = ["\(thread.status.label)", "\(stats.completedSteps) 步"]
        if stats.readCount > 0 { parts.append("读 \(stats.readCount) 个文件") }
        if stats.failureCount > 0 { parts.append("失败 \(stats.failureCount) 项") }
        if stats.recoveryCount > 0 {
            parts.append("恢复 \(stats.recoverySuccessCount)/\(stats.recoveryCount)")
        }
        parts.append(RelativeTimeFormatter.string(for: thread.updatedAt))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Typing Indicator

private struct TypingIndicator: View {
    @EnvironmentObject private var store: AppStore
    @State private var phase: Int = 0
    @State private var tick: Int = 0  // drives 1-second refresh
    @State private var pulseTimer: Timer?
    @State private var tickTimer: Timer?

    private var activityText: String {
        let text = store.state.liveActivity
        return text.isEmpty ? "正在处理…" : text
    }

    private var elapsed: Int {
        guard let start = store.state.generationStartedAt else { return 0 }
        let _ = tick  // subscribe to tick so label updates every second
        return max(0, Int(Date().timeIntervalSince(start)))
    }

    var body: some View {
        HStack(spacing: AppSpace.sm) {
            HStack(spacing: AppSpace.sm) {
                // Pulsing dot
                Circle()
                    .fill(Brand.primary)
                    .frame(width: 7, height: 7)
                    .scaleEffect(phase == 0 ? 1.0 : 0.7)
                    .opacity(phase == 0 ? 1.0 : 0.5)

                Text(activityText)
                    .font(AppFont.captionMedium)
                    .foregroundStyle(TextGrade.secondary)
                    .lineLimit(1)

                if elapsed > 0 {
                    Text(elapsedLabel)
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.ghost)
                }

                if let progress = store.state.estimatedProgress {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Brand.primary)
                }
            }
            .padding(.horizontal, AppSpace.lg)
            .padding(.vertical, AppSpace.sm + 2)
            .background(
                Capsule()
                    .fill(SurfaceGrade.card)
                    .overlay(Capsule().strokeBorder(Brand.primary.opacity(0.12), lineWidth: 1))
            )
            .shadow(color: .black.opacity(0.035), radius: 3, y: 1)

            Spacer()
        }
        .onAppear { startTimers() }
        .onDisappear { stopTimers() }
    }

    private var elapsedLabel: String {
        let e = elapsed
        if e < 60 { return "\(e)s" }
        return "\(e / 60)m\(e % 60)s"
    }

    private func startTimers() {
        guard pulseTimer == nil else { return }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in
            phase = phase == 0 ? 1 : 0
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            tick += 1
        }
    }

    private func stopTimers() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        tickTimer?.invalidate()
        tickTimer = nil
    }
}

// TaskStepCard, UserInputCard, ThinkingCard, ToolCallCard, ToolResultCard,
// TextOutputCard, PausedCard, FailedCard, ReviewCard, ReviewResultCard,
// AvatarBadge, DiffPreviewCard, ProgressGlyph, ContinuationStrategyBar
// → TimelineCards.swift

// Step Cards → TimelineCards.swift
// WelcomeView → WelcomePage.swift

// MARK: - Batch Review Bar

struct BatchReviewBar: View {
    @EnvironmentObject private var store: AppStore
    let pendingCount: Int
    let taskID: UUID
    let stepIDs: [UUID]
    @State private var isApproving = false
    @State private var isRejecting = false

    var body: some View {
        HStack(spacing: AppSpace.md) {
            Image(systemName: "eye.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Semantic.warning)

            Text("\(pendingCount) 个变更待审查")
                .font(AppFont.subheadline)
                .foregroundStyle(TextGrade.primary)

            Spacer()

            Button {
                isApproving = true
                for stepID in stepIDs {
                    store.approveReview(taskID: taskID, stepID: stepID)
                }
                isApproving = false
            } label: {
                HStack(spacing: AppSpace.xs) {
                    if isApproving {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text("全部批准")
                        .font(AppFont.captionMedium)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, AppSpace.lg)
                .padding(.vertical, AppSpace.sm + 2)
                .background(Capsule().fill(Semantic.success))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("a", modifiers: [.command, .shift])

            Button {
                isRejecting = true
                for stepID in stepIDs {
                    store.rejectReview(taskID: taskID, stepID: stepID)
                }
                isRejecting = false
            } label: {
                HStack(spacing: AppSpace.xs) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("全部拒绝")
                        .font(AppFont.captionMedium)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, AppSpace.lg)
                .padding(.vertical, AppSpace.sm + 2)
                .background(Capsule().fill(Semantic.error))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AppSpace.lg)
        .padding(.vertical, AppSpace.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(Semantic.warning.opacity(0.30), lineWidth: 1)
        )
        .padding(.horizontal, AppSpace.xl)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Task Completion Summary Card

private struct TaskCompletionSummaryCard: View {
    let thread: Thread

    private var writtenFiles: [String] {
        let reviewApproved = thread.steps.filter { $0.kind == .reviewRequest && $0.approved == true }
            .compactMap { $0.diffFilePath }
        let directWrites = thread.steps.filter { $0.kind == .toolResult && $0.toolName == "file.write" && !$0.isFailure }
            .compactMap { $0.toolParams?["path"] }
        let edits = thread.steps.filter { $0.kind == .toolResult && $0.toolName == "file.edit" && !$0.isFailure }
            .compactMap { $0.toolParams?["path"] }
        let patches = thread.steps.filter { $0.kind == .toolResult && $0.toolName == "diff.apply" && !$0.isFailure }
            .compactMap { $0.toolParams?["path"] ?? $0.toolParams?["file"] }
        return Array(Set(reviewApproved + directWrites + edits + patches)).sorted()
    }

    private var failedSteps: [TaskStep] {
        thread.steps.filter { ($0.isFailure || $0.kind == .error) && $0.kind != .userInput }
    }

    private var shellCommands: [String] {
        thread.steps.filter { $0.kind == .toolCall && $0.toolName == "shell.exec" }
            .compactMap { $0.toolParams?["command"] }
    }

    private var verifyCount: Int {
        thread.steps.filter { $0.kind == .toolResult && $0.toolName == "verify.build" }.count
    }

    private var duration: String? {
        let interval = thread.updatedAt.timeIntervalSince(thread.createdAt)
        guard interval > 1 else { return nil }
        if interval < 60 { return "\(Int(interval))秒" }
        if interval < 3600 { return "\(Int(interval / 60))分\(Int(interval.truncatingRemainder(dividingBy: 60)))秒" }
        return "\(Int(interval / 3600))时\(Int((interval.truncatingRemainder(dividingBy: 3600)) / 60))分"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            // Header
            HStack(spacing: AppSpace.sm) {
                Image(systemName: thread.status == .completed ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(thread.status == .completed ? Semantic.success : Semantic.error)
                Text(thread.agentState == .completed || thread.status == .completed ? "会话完成" : "会话失败")
                    .font(AppFont.subheadline)
                    .foregroundStyle(thread.status == .completed ? Semantic.success : Semantic.error)
                if let dur = duration {
                    Text("· \(dur)")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                }
                Spacer()
            }

            // Changed files
            if !writtenFiles.isEmpty {
                VStack(alignment: .leading, spacing: AppSpace.xs) {
                    HStack(spacing: AppSpace.xs) {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(TextGrade.secondary)
                        Text("变更文件（\(writtenFiles.count)）")
                            .font(AppFont.captionMedium)
                            .foregroundStyle(TextGrade.secondary)
                    }
                    ForEach(writtenFiles.prefix(8), id: \.self) { path in
                        HStack(spacing: AppSpace.xs) {
                            Text("•")
                                .foregroundStyle(Brand.primary)
                            Text(shortPath(path))
                                .font(AppFont.caption)
                                .foregroundStyle(TextGrade.primary)
                                .lineLimit(1)
                        }
                    }
                    if writtenFiles.count > 8 {
                        Text("+\(writtenFiles.count - 8) 个文件…")
                            .font(AppFont.tiny)
                            .foregroundStyle(TextGrade.ghost)
                    }
                }
                .padding(AppSpace.sm)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                        .fill(SurfaceGrade.sunken.opacity(0.5))
                )
            }

            // Failed items
            if !failedSteps.isEmpty {
                VStack(alignment: .leading, spacing: AppSpace.xs) {
                    HStack(spacing: AppSpace.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Semantic.error)
                        Text("失败项（\(failedSteps.count)）")
                            .font(AppFont.captionMedium)
                            .foregroundStyle(Semantic.error)
                    }
                    ForEach(failedSteps.prefix(5), id: \.id) { step in
                        HStack(spacing: AppSpace.xs) {
                            Text("•")
                                .foregroundStyle(Semantic.error)
                            Text(step.toolName ?? step.kind.title)
                                .font(AppFont.caption)
                                .foregroundStyle(TextGrade.primary)
                            if !step.text.isEmpty {
                                Text("— \(String(step.text.prefix(60)))")
                                    .font(AppFont.tiny)
                                    .foregroundStyle(TextGrade.muted)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(AppSpace.sm)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                        .fill(Semantic.errorMuted.opacity(0.5))
                )
            }

            // Shell commands summary
            if !shellCommands.isEmpty {
                HStack(spacing: AppSpace.xs) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                        .foregroundStyle(TextGrade.secondary)
                    Text("执行了 \(shellCommands.count) 条命令")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                }
            }

            if verifyCount > 0 {
                HStack(spacing: AppSpace.xs) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 10))
                        .foregroundStyle(Semantic.success)
                    Text("验证了 \(verifyCount) 次")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                }
            }
        }
        .padding(AppSpace.lg)
        .frame(maxWidth: 580, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .fill(SurfaceGrade.card.opacity(0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(
                    thread.status == .completed
                    ? Semantic.success.opacity(0.20)
                    : Semantic.error.opacity(0.20),
                    lineWidth: 0.7
                )
        )
    }

    private func shortPath(_ path: String) -> String {
        let components = path.components(separatedBy: "/")
        if components.count <= 2 { return path }
        return components.suffix(2).joined(separator: "/")
    }
}

// MARK: - Task Rating Bar

private struct TaskRatingBar: View {
    @EnvironmentObject private var store: AppStore
    let threadID: UUID
    let currentRating: Int

    var body: some View {
        HStack(spacing: AppSpace.sm) {
            Text("评价此结果")
                .font(AppFont.caption)
                .foregroundStyle(TextGrade.muted)
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        store.rateThread(id: threadID, rating: star)
                    } label: {
                        Image(systemName: star <= currentRating ? "star.fill" : "star")
                            .font(.system(size: 13))
                            .foregroundStyle(star <= currentRating ? Color.yellow : TextGrade.muted.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            if currentRating > 0 {
                Text(ratingLabel)
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, AppSpace.md)
        .padding(.vertical, AppSpace.xs)
    }

    private var ratingLabel: String {
        switch currentRating {
        case 1: return "很差"
        case 2: return "不太好"
        case 3: return "一般"
        case 4: return "不错"
        case 5: return "很棒"
        default: return ""
        }
    }
}
