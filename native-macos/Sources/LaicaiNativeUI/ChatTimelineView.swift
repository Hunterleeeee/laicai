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
        .accessibilityLabel(tooltip.isEmpty ? icon : tooltip)
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

/// Reports the bottom anchor's maxY within the timeline scroll space so the
/// view can stop auto-scrolling the moment the user reads older content.
private struct BottomAnchorMaxYKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Zero-size observer for StreamTextStore revisions. Lives inside the
/// ScrollViewReader scope so a token flush can trigger scroll-follow without
/// invalidating any visible card other than the streaming one itself.
private struct StreamScrollFollowDriver: View {
    @ObservedObject private var streams: StreamTextStore
    private let onTick: () -> Void

    init(streams: StreamTextStore, onTick: @escaping () -> Void) {
        self._streams = ObservedObject(wrappedValue: streams)
        self.onTick = onTick
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: streams.revision) { _, _ in
                onTick()
            }
    }
}

struct ThreadTimelineView: View {
    @ObservedObject private var generationPresentation: GenerationPresentationStore
    /// Passed down to streaming cards only; deliberately NOT observed here so
    /// token-level flushes never re-render the whole timeline.
    private let streamPresentation: StreamTextStore
    let thread: Thread
    let connectors: [ConnectorProfile]
    let activeConnectorID: UUID?
    let workspaceRoot: String
    let userRating: Int
    /// Read once by the owner (ChatDetailView) so step cards never observe
    /// AppStore themselves.
    let showsDebugPanels: Bool
    let onPlanChange: (MultiAgentPlan) -> Void
    let onExecutePlan: () -> Void
    let onCancelPlan: () -> Void
    let onResumePlan: () -> Void

    init(
        thread: Thread,
        generationPresentation: GenerationPresentationStore,
        streamPresentation: StreamTextStore,
        connectors: [ConnectorProfile],
        activeConnectorID: UUID?,
        workspaceRoot: String,
        userRating: Int,
        showsDebugPanels: Bool,
        onPlanChange: @escaping (MultiAgentPlan) -> Void,
        onExecutePlan: @escaping () -> Void,
        onCancelPlan: @escaping () -> Void,
        onResumePlan: @escaping () -> Void
    ) {
        self.thread = thread
        self._generationPresentation = ObservedObject(wrappedValue: generationPresentation)
        self.streamPresentation = streamPresentation
        self.connectors = connectors
        self.activeConnectorID = activeConnectorID
        self.workspaceRoot = workspaceRoot
        self.userRating = userRating
        self.showsDebugPanels = showsDebugPanels
        self.onPlanChange = onPlanChange
        self.onExecutePlan = onExecutePlan
        self.onCancelPlan = onCancelPlan
        self.onResumePlan = onResumePlan
    }
    private let bottomID = "thread-bottom-anchor"
    private let compactStepLimit = 12
    private let runningStepLimit = 8
    // Keep enough context visible for long multi-agent runs; the timeline
    // still offers an explicit full-history switch for very large sessions.
    private let heavyStepLimit = 20
    private let heavyThreadThreshold = 80
    @State private var scrollToken = 0
    @State private var showFullHistory = false
    @State private var userScrolledAway = false
    @State private var expandedPhases: Set<String> = []
    @State private var viewportHeight: CGFloat = 0
    @State private var cachedStatsSignature: Int?
    @State private var cachedExecutionStats: TaskStepStats?
    @State private var cachedPhaseGroupsSignature: Int?
    @State private var cachedPhaseGroups: [StepPhaseGroup] = []

    var body: some View {
        let executionSteps = thread.isExecution ? visibleSteps(for: thread) : []
        let currentSignature = timelineStructureSignature
        let executionStats = thread.isExecution
            ? (cachedStatsSignature == currentSignature ? cachedExecutionStats : TaskStepStats(thread: thread, visibleSteps: executionSteps))
            : nil
        let displayedPhaseGroups = cachedPhaseGroupsSignature == currentSignature
            ? cachedPhaseGroups
            : phaseGroups(for: executionSteps)
        let sessionSteps = thread.isExecution ? [] : visibleSessionSteps
        let showsEmptyRunningState = thread.steps.isEmpty

        return ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppSpace.extraLarge) {
                        if thread.isExecution, let executionStats {
                            TaskSummaryCard(thread: thread, stats: executionStats, connectors: connectors)
                            if thread.status == .completed || thread.status == .failed {
                                TaskCompletionSummaryCard(thread: thread)
                                TaskRatingBar(
                                    threadID: thread.id,
                                    currentRating: userRating)
                            }
                            if let plan = thread.multiAgentPlan {
                                if plan.isEditable {
                                    MultiAgentPlanEditorView(
                                        plan: Binding(
                                            get: {
                                                plan
                                            },
                                            set: { newPlan in
                                                onPlanChange(newPlan)
                                            }
                                        ),
                                        connectors: connectors,
                                        activeConnectorID: activeConnectorID,
                                        workspaceRoot: workspaceRoot,
                                        onExecute: {
                                            onExecutePlan()
                                        },
                                        onCancel: {
                                            onCancelPlan()
                                        }
                                    )
                                } else {
                                    MultiAgentFlowView(plan: plan)
                                    ResumePlanButton(plan: plan) {
                                        onResumePlan()
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
                            ForEach(displayedPhaseGroups) { group in
                                if group.isToolPhase {
                                    PhaseGroupCard(
                                        group: group,
                                        taskID: thread.id,
                                        isRunning: thread.status == .running,
                                        isCollapsed: !expandedPhases.contains(group.id),
                                        showsDebugPanels: showsDebugPanels,
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
                                            isRunning: thread.status == .running,
                                            showsDebugPanels: showsDebugPanels,
                                            live: liveStreamSource(for: step)
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
                                SessionStepCard(step: step, live: liveStreamSource(for: step))
                                    .id(step.id)
                            }
                        }

                        if generationPresentation.snapshot(for: thread.id).isGenerating {
                            TypingIndicator(threadID: thread.id)
                        }
                    }
                    .frame(maxWidth: LayoutConst.conversationMaxWidth, alignment: .leading)
                    .padding(.horizontal, AppSpace.xxl)
                    .padding(.top, AppSpace.xxl)
                    .padding(.bottom, AppSpace.extraLarge)
                    .frame(maxWidth: .infinity, alignment: .center)

                    // Keep the anchor outside the LazyVStack so it is never
                    // reclaimed while the user scrolls up. Its position in
                    // the scroll coordinate space drives auto-scroll follow.
                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: BottomAnchorMaxYKey.self,
                                    value: proxy.frame(in: .named("timeline-scroll")).maxY
                                )
                            }
                        )
                }
                .coordinateSpace(name: "timeline-scroll")
                .background(SurfaceGrade.base)
                // Track the visible viewport height so the bottom-anchor
                // position can determine whether the user is at the bottom.
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { viewportHeight = proxy.size.height }
                            .onChange(of: proxy.size.height) { _, h in viewportHeight = h }
                    }
                )
                .onAppear {
                    rebuildDerivedTimeline()
                    scrollToBottom(proxy)
                }
                .onChange(of: timelineStructureSignature) { _, _ in
                    rebuildDerivedTimeline()
                }
                .onChange(of: thread.steps.count) { _, _ in scheduleScrollToBottom(proxy) }
                .onChange(of: generationPresentation.revision) { _, _ in
                    // Streaming deltas bump the revision without adding steps;
                    // follow the growing output unless the user scrolled away.
                    guard generationPresentation.snapshot(for: thread.id).isGenerating else { return }
                    scheduleScrollToBottom(proxy)
                }
                .onChange(of: generationPresentation.snapshot(for: thread.id).isGenerating) { _, isGen in
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
                // Real scroll-awareness: when the bottom anchor is above the
                // visible viewport, the user has scrolled away — stop
                // stealing their reading position. While generating, content
                // growth constantly pushes the anchor out of view, so only a
                // deliberate scroll (well past half a screen) counts as
                // leaving; otherwise every long stream popped the
                // "scroll to bottom" button mid-generation.
                .onPreferenceChange(BottomAnchorMaxYKey.self) { maxY in
                    guard maxY.isFinite, viewportHeight > 0 else { return }
                    let isGenerating = generationPresentation.snapshot(for: thread.id).isGenerating
                    let threshold = isGenerating ? max(240.0, viewportHeight * 0.55) : 80.0
                    let shouldBeScrolledAway = maxY > viewportHeight + threshold
                    if userScrolledAway != shouldBeScrolledAway {
                        userScrolledAway = shouldBeScrolledAway
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

                // Streaming text revisions drive scroll-follow from a
                // zero-size observer so the timeline itself never re-renders
                // on token flushes.
                StreamScrollFollowDriver(streams: streamPresentation) {
                    guard generationPresentation.snapshot(for: thread.id).isGenerating else { return }
                    scheduleScrollToBottom(proxy)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Returns a live source only for the transient streaming placeholders;
    /// completed steps render their own persisted text.
    private func liveStreamSource(for step: TaskStep) -> LiveStreamSource? {
        guard step.toolCallId == AppStore.streamingOutputID || step.toolCallId == AppStore.thinkingStreamID else {
            return nil
        }
        return LiveStreamSource(store: streamPresentation, threadID: thread.id)
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

    /// Streaming text updates the existing card; scrolling is handled by the
    /// generation/step-count changes below, avoiding periodic full projections.

    private var timelineStructureSignature: Int {
        var hasher = Hasher()
        hasher.combine(thread.id)
        hasher.combine(thread.status.rawValue)
        hasher.combine(thread.steps.count)
        hasher.combine(showFullHistory)
        let signatureSteps = visibleSteps(for: thread)
        for step in signatureSteps {
            hasher.combine(step.id)
            hasher.combine(step.kind.rawValue)
            hasher.combine(step.toolCallId)
            hasher.combine(step.continuationOf)
            hasher.combine(step.isFailure)
            hasher.combine(step.approved)
        }
        // Text deltas update the existing output card and must not invalidate
        // O(n) phase/stat projections. Structural changes (count/kind/id) above
        // are sufficient to rebuild those projections.
        return hasher.finalize()
    }

    private func rebuildDerivedTimeline() {
        let signature = timelineStructureSignature
        let steps = thread.isExecution ? visibleSteps(for: thread) : []
        cachedExecutionStats = thread.isExecution ? TaskStepStats(thread: thread, visibleSteps: steps) : nil
        cachedStatsSignature = signature
        cachedPhaseGroups = phaseGroups(for: steps)
        cachedPhaseGroupsSignature = signature
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
        // Merge continuation textOutput steps into their originals. Index the
        // base steps once instead of scanning the merged array for every part.
        let continuations = steps.filter { $0.continuationOf != nil && $0.kind == .textOutput }
        guard !continuations.isEmpty else { return steps }
        var merged = steps.filter { $0.continuationOf == nil || $0.kind != .textOutput }
        var indexByID = Dictionary(uniqueKeysWithValues: merged.enumerated().map { ($0.element.id, $0.offset) })
        for cont in continuations {
            if let idx = cont.continuationOf.flatMap({ indexByID[$0] }) {
                var step = merged[idx]
                step.text += "\n" + cont.text
                step.metrics = step.metrics ?? cont.metrics
                step.continuationOf = nil
                merged[idx] = step
            } else {
                indexByID[cont.id] = merged.count
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

