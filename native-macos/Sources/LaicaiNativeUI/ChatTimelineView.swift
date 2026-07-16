import AppKit
import LaicaiNativeDomain
import LaicaiNativeFoundation
import SwiftUI

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
                    RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                        .fill(isHovered ? SurfaceGrade.hover : SurfaceGrade.elevated.opacity(0.72))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                        .strokeBorder(isHovered ? SurfaceGrade.border.opacity(0.8) : SurfaceGrade.hairline, lineWidth: 0.6)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in withAnimation(AppAnimation.micro) { isHovered = isHovering } }
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
        let executionSteps = thread.isExecution ? visibleSteps(for: thread) : []
        let executionStats = thread.isExecution ? TaskStepStats(thread: thread, visibleSteps: executionSteps) : nil
        let sessionSteps = thread.isExecution ? [] : visibleSessionSteps
        let showsEmptyRunningState = thread.steps.isEmpty

        return ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppSpace.extraLarge) {
                        if thread.isExecution, let executionStats {
                            TaskSummaryCard(thread: thread, stats: executionStats, connectors: store.state.connectors)
                            if thread.status == .completed || thread.status == .failed {
                                TaskCompletionSummaryCard(thread: thread)
                                TaskRatingBar(
                                    threadID: thread.id,
                                    currentRating: store.state.threads.first(where: { $0.id == thread.id })?.userRating ?? 0)
                            }
                            if let plan = thread.multiAgentPlan {
                                if plan.isEditable {
                                    MultiAgentPlanEditorView(
                                        plan: Binding(
                                            get: {
                                                store.state.threads.first(where: { $0.id == thread.id })?.multiAgentPlan ?? plan
                                            },
                                            set: { newPlan in
                                                store.updateMultiAgentPlan(newPlan, for: thread.id)
                                            }
                                        ),
                                        connectors: store.state.connectors,
                                        activeConnectorID: store.state.activeConnectorID,
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

                        if store.isThreadGenerating(thread.id) {
                            TypingIndicator(threadID: thread.id)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                    }
                    .frame(maxWidth: LayoutConst.conversationMaxWidth, alignment: .leading)
                    .padding(.horizontal, AppSpace.xxl)
                    .padding(.top, AppSpace.xxl)
                    .padding(.bottom, AppSpace.extraLarge)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .coordinateSpace(name: "timeline-scroll")
                .background(SurfaceGrade.base)
                .onAppear {
                    scrollToBottom(proxy)
                }
                .onChange(of: thread.steps.count) { _, _ in scheduleScrollToBottom(proxy) }
                .onChange(of: store.isThreadGenerating(thread.id)) { _, isGen in
                    if isGen {
                        userScrolledAway = false
                        scheduleScrollToBottom(proxy)
                    }
                }
                .onChange(of: thread.status) { _, newStatus in
                    if newStatus == .running {
                        userScrolledAway = false
                        scheduleScrollToBottom(proxy)
                    }
                }
                .onChange(of: streamingTextLength) { _, _ in scheduleScrollToBottom(proxy) }
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
                        .padding(.bottom, AppSpace.extraLarge)
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
                    .padding(.bottom, AppSpace.extraLarge)
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
        VStack(alignment: .leading, spacing: AppSpace.medium) {
            HStack(spacing: AppSpace.medium) {
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
        .padding(AppSpace.large)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(SurfaceGrade.card.opacity(0.84))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .strokeBorder(Semantic.toolRunning.opacity(0.20), lineWidth: 0.7)
        )
    }

    private var statusLine: String {
        if thread.multiAgentPlan != nil { return "多会话计划已创建，正在启动第一步…" }
        if thread.status == .running || thread.executionState == .running { return "会话已创建，正在准备上下文…" }
        return "正在准备…"
    }

    private var visibleGoal: String? {
        let raw =
            thread.goal?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? thread.executionLedger?.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }
}

private struct TaskHistoryFoldCard: View {
    let hiddenCount: Int
    @Binding var showFullHistory: Bool

    var body: some View {
        HStack(alignment: .center, spacing: AppSpace.small) {
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
        .padding(.horizontal, AppSpace.medium)
        .padding(.vertical, AppSpace.small)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(SurfaceGrade.elevated.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(SurfaceGrade.hairline.opacity(0.8), lineWidth: 0.6)
        )
    }
}

private struct ThreadSummaryCard: View {
    let thread: ThreadRecord

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.small) {
            HStack(spacing: AppSpace.small) {
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
                    Text(threadSubtitle)
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
                    .padding(AppSpace.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                            .fill(SurfaceGrade.panel.opacity(0.75))
                    )
            }
        }
        .padding(AppSpace.large)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(SurfaceGrade.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(SurfaceGrade.divider, lineWidth: 0.75)
        )
    }

    private var threadSubtitle: String {
        let updatedAt = RelativeTimeFormatter.string(for: thread.updatedAt)
        return "会话 · \(thread.resolvedAgentState.title) · \(thread.events.count) 条记录 · \(updatedAt)"
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
            TextOutputCard(
                text: step.text, metrics: step.metrics, isRunning: step.metrics == nil && step.toolCallId == AppStore.streamingOutputID)
        case .aiThinking:
            ThinkingCard(text: step.text, reasoningContent: step.reasoningContent, isRunning: false)
        case .toolCall:
            timelineSystemCard(icon: "wrench.and.screwdriver.fill", title: "工具调用", text: step.text, color: Semantic.toolCall)
        case .toolResult:
            timelineSystemCard(
                icon: "checkmark.circle.fill", title: "工具结果", text: step.text, color: step.isFailure ? Semantic.error : Semantic.success)
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
        return HStack(alignment: .top, spacing: AppSpace.small) {
            AvatarBadge(icon: icon, color: color)

            VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
                Text(title)
                    .font(AppFont.captionMedium)
                    .foregroundStyle(color)

                Text(display)
                    .font(AppFont.body)
                    .foregroundStyle(TextGrade.secondary)
                    .lineLimit(8)
                    .padding(AppSpace.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                            .fill(SurfaceGrade.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                            .strokeBorder(color.opacity(0.18), lineWidth: 1)
                    )
            }

            Spacer()
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

    var stepIndex = 0
    while stepIndex < steps.count {
        let step = steps[stepIndex]
        if step.kind == .toolCall || step.kind == .toolResult {
            flushNonTool()
            var toolSteps: [TaskStep] = []
            while stepIndex < steps.count && (steps[stepIndex].kind == .toolCall || steps[stepIndex].kind == .toolResult) {
                toolSteps.append(steps[stepIndex])
                stepIndex += 1
            }
            let anchor = toolSteps[0].id.uuidString
            let phase = AgentLoop.inferPhase(from: toolSteps)
            groups.append(StepPhaseGroup(id: "tool-\(anchor)", phase: phase, steps: toolSteps))
        } else {
            currentNonTool.append(step)
            stepIndex += 1
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
                HStack(spacing: AppSpace.small) {
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
                .padding(.horizontal, AppSpace.medium)
                .padding(.vertical, AppSpace.small)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                        .fill(SurfaceGrade.card.opacity(0.55))
                )
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                VStack(alignment: .leading, spacing: AppSpace.small) {
                    ForEach(group.steps) { step in
                        TaskStepCard(step: step, taskID: taskID, isRunning: isRunning)
                            .id(step.id)
                    }
                }
                .padding(.leading, AppSpace.extraLarge)
                .padding(.top, AppSpace.extraSmall)
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
        let accumulator = TaskStepStatsAccumulator(steps: visibleSteps)

        self.completedSteps = accumulator.completedSteps
        self.failureCount = accumulator.failureCount
        self.recoveryCount = accumulator.recoveryCount
        self.recoverySuccessCount = accumulator.recoverySuccessCount
        self.readCount = accumulator.readCount
        self.pendingReviewIDs = accumulator.pendingReviewIDs
        self.currentPhase = accumulator.currentPhase
        self.phaseCounts = accumulator.phaseCounts
        self.phaseTools = accumulator.phaseToolSets.mapValues { $0.sorted() }
        self.memoryPills = accumulator.memoryPills
    }

    func tools(for phase: TaskPhase) -> [String] {
        phaseTools[phase] ?? []
    }

    fileprivate static func appendUnique(_ value: String, to values: inout [String], seen: inout Set<String>) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !seen.contains(trimmed) else { return }
        seen.insert(trimmed)
        values.append(trimmed)
    }

    fileprivate static func isSuccessfulDocumentTransform(_ step: TaskStep, canonicalToolName: String) -> Bool {
        guard step.kind == .toolResult,
            canonicalToolName == "document.transform",
            !step.isFailure
        else { return false }
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

    fileprivate static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        if parts.count <= 2 { return path }
        return parts.suffix(2).joined(separator: "/")
    }
}

private struct TaskStepStatsAccumulator {
    private static let exploreTools = ["workspace.index", "file.read", "code.search", "git"]
    private static let executionTools = ["file.write", "file.edit", "diff.apply", "shell.exec"]
    private static let fileMutationTools = ["file.write", "file.edit", "diff.apply"]

    var completedSteps = 0
    var failureCount = 0
    var recoveryCount = 0
    var recoverySuccessCount = 0
    var readCount = 0
    var pendingReviewIDs: [UUID] = []
    var phaseCounts: [TaskPhase: Int] = [:]
    var phaseToolSets: [TaskPhase: Set<String>] = [:]

    private var readFiles: [String] = []
    private var seenReadFiles: Set<String> = []
    private var hasWorkspaceIndex = false
    private var failedToolCounts: [String: Int] = [:]
    private var searches: [String] = []
    private var seenSearches: Set<String> = []
    private var hasFileChange = false
    private var hasVerifyCheck = false
    private var successfulReadCount = 0
    private var searchCount = 0
    private let lastStepKind: TaskStepKind?

    init(steps: [TaskStep]) {
        lastStepKind = steps.last?.kind
        for step in steps {
            record(step)
        }
    }

    var currentPhase: TaskPhase {
        if lastStepKind == .textOutput && hasVerifyCheck {
            return .summarize
        }
        if hasVerifyCheck || hasFileChange {
            return .verify
        }
        if successfulReadCount + searchCount >= 3 {
            return .execute
        }
        return .explore
    }

    var memoryPills: [String] {
        var pills: [String] = []
        appendReadFilePill(to: &pills)
        if hasWorkspaceIndex {
            pills.append("已有索引")
        }
        if let firstFailure = firstFailureSummary {
            pills.append("失败 \(firstFailure)")
        }
        if let firstSearch = searches.first {
            pills.append("搜过 \(String(firstSearch.prefix(18)))")
        }
        if recoveryCount > 0 {
            pills.append("自动恢复 ×\(recoveryCount)")
        }
        return pills
    }

    private mutating func record(_ step: TaskStep) {
        recordCommonCounts(step)
        if let toolName = step.toolName.map(ToolNameCodec.canonicalName) {
            recordToolStep(step, toolName: toolName)
        }
        recordNonToolPhase(step)
    }

    private mutating func recordCommonCounts(_ step: TaskStep) {
        if step.kind != .userInput {
            completedSteps += 1
        }
        if step.isFailure || step.kind == .error {
            failureCount += 1
        }
        if isRecovery(step) {
            recoveryCount += 1
            if !step.isFailure && step.kind == .toolResult {
                recoverySuccessCount += 1
            }
        }
        if step.kind == .reviewRequest && step.approved == nil {
            pendingReviewIDs.append(step.id)
        }
    }

    private mutating func recordToolStep(_ step: TaskStep, toolName: String) {
        recordToolPhase(step, toolName: toolName)
        recordFileChange(step, toolName: toolName)
        recordReadEvidence(step, toolName: toolName)
        recordFailures(step, toolName: toolName)
        recordSearch(step, toolName: toolName)
    }

    private mutating func recordToolPhase(_ step: TaskStep, toolName: String) {
        if Self.exploreTools.contains(toolName), step.kind == .toolCall || step.kind == .toolResult {
            addPhase(.explore, toolName: toolName)
        }
        if step.kind == .toolCall, Self.executionTools.contains(toolName) {
            addPhase(.execute, toolName: toolName)
        }
        if step.kind == .toolCall, toolName == "verify.build" {
            addPhase(.verify, toolName: toolName)
        }
        if isShellTestCommand(step, toolName: toolName) {
            addPhase(.verify, toolName: toolName)
        }
    }

    private mutating func recordFileChange(_ step: TaskStep, toolName: String) {
        if Self.fileMutationTools.contains(toolName)
            || TaskStepStats.isSuccessfulDocumentTransform(step, canonicalToolName: toolName)
        {
            hasFileChange = true
        }
    }

    private mutating func recordReadEvidence(_ step: TaskStep, toolName: String) {
        if step.kind == .toolResult, toolName == "file.read", !step.isFailure {
            readCount += 1
            successfulReadCount += 1
            if let path = step.toolParams?["path"] {
                TaskStepStats.appendUnique(path, to: &readFiles, seen: &seenReadFiles)
            }
        }
        if step.kind == .toolResult, toolName == "workspace.index", !step.isFailure {
            hasWorkspaceIndex = true
        }
    }

    private mutating func recordFailures(_ step: TaskStep, toolName: String) {
        if step.kind == .toolResult, step.isFailure {
            failedToolCounts[toolName, default: 0] += 1
        }
    }

    private mutating func recordSearch(_ step: TaskStep, toolName: String) {
        if step.kind == .toolCall, toolName == "code.search" {
            searchCount += 1
            if let query = step.toolParams?["query"] {
                TaskStepStats.appendUnique(query, to: &searches, seen: &seenSearches)
            }
        }
    }

    private mutating func recordNonToolPhase(_ step: TaskStep) {
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

    private mutating func addPhase(_ phase: TaskPhase, toolName: String? = nil) {
        phaseCounts[phase, default: 0] += 1
        guard let toolName, !toolName.isEmpty else { return }
        phaseToolSets[phase, default: []].insert(ToolNameCodec.canonicalName(toolName))
    }

    private func appendReadFilePill(to pills: inout [String]) {
        if let first = readFiles.first {
            let extra = readFiles.count > 1 ? " +\(readFiles.count - 1)" : ""
            pills.append("已读 \(TaskStepStats.shortPath(first))\(extra)")
        }
    }

    private var firstFailureSummary: String? {
        failedToolCounts
            .map { "\($0.key) ×\($0.value)" }
            .sorted()
            .first
    }

    private func isRecovery(_ step: TaskStep) -> Bool {
        (step.toolCallId ?? "").hasPrefix("call_recovery_") || step.text.hasPrefix("自动恢复")
    }

    private func isShellTestCommand(_ step: TaskStep, toolName: String) -> Bool {
        step.kind == .toolCall
            && toolName == "shell.exec"
            && step.toolParams?["command"]?.contains("test") == true
    }
}

private struct TaskSummaryCard: View {
    let thread: Thread
    let stats: TaskStepStats
    let connectors: [ConnectorProfile]

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.medium) {
            HStack(alignment: .center, spacing: AppSpace.medium) {
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

                    // Intent & connector pills
                    HStack(spacing: AppSpace.extraSmall) {
                        intentPill
                        if let connectorName = resolvedConnectorName {
                            connectorPill(connectorName)
                        }
                    }
                    .padding(.top, 2)

                    if !stats.memoryPills.isEmpty {
                        HStack(spacing: AppSpace.extraSmall) {
                            ForEach(stats.memoryPills.prefix(3), id: \.self) { pill in
                                Text(pill)
                                    .font(AppFont.tiny)
                                    .foregroundStyle(TextGrade.secondary)
                                    .lineLimit(1)
                                    .padding(.horizontal, AppSpace.small)
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
        .padding(AppSpace.large)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(SurfaceGrade.card.opacity(0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
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

        return VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
            // Phase indicator row
            HStack(spacing: 2) {
                ForEach(Array(phases.enumerated()), id: \.offset) { index, phase in
                    let stepCount = stats.phaseCounts[phase] ?? 0
                    let tools = stats.tools(for: phase)
                    let isDone = index < currentIndex || (!isRunning && index <= currentIndex)

                    VStack(spacing: 2) {
                        HStack(spacing: AppSpace.extraSmall) {
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
                        .padding(.horizontal, AppSpace.small)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
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

    // MARK: - Intent & Connector Display

    private enum IntentMode: String {
        case chat = "问答"
        case research = "研究"
        case task = "执行"
        case workflow = "工作流"

        var icon: String {
            switch self {
            case .chat: return "bubble.left.and.bubble.right"
            case .research: return "magnifyingglass"
            case .task: return "hammer"
            case .workflow: return "arrow.triangle.branch"
            }
        }

        var color: Color {
            switch self {
            case .chat: return .blue
            case .research: return .purple
            case .task: return .orange
            case .workflow: return .green
            }
        }
    }

    private var inferredIntent: IntentMode {
        if thread.workflowName != nil { return .workflow }
        let hasToolCalls = thread.steps.contains { $0.kind == .toolCall }
        let hasSearch = thread.steps.contains { $0.toolName == "web.search" || $0.toolName == "web_fetch" }
        if hasSearch && !hasToolCalls { return .research }
        return hasToolCalls ? .task : .chat
    }

    private var resolvedConnectorName: String? {
        guard let connectorID = thread.connectorID else { return nil }
        return connectors.first(where: { $0.id == connectorID })?.name
    }

    private var intentPill: some View {
        let intent = inferredIntent
        return HStack(spacing: 4) {
            Image(systemName: intent.icon)
                .font(.system(size: 9, weight: .semibold))
            Text(intent.rawValue + "模式")
                .font(AppFont.tiny)
                .fontWeight(.medium)
        }
        .foregroundStyle(intent.color)
        .padding(.horizontal, AppSpace.small)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(intent.color.opacity(0.12))
        )
    }

    private func connectorPill(_ name: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "cpu")
                .font(.system(size: 9, weight: .semibold))
            Text(name)
                .font(AppFont.tiny)
                .fontWeight(.medium)
                .lineLimit(1)
        }
        .foregroundStyle(TextGrade.secondary)
        .padding(.horizontal, AppSpace.small)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(SurfaceGrade.sunken.opacity(0.72))
        )
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
