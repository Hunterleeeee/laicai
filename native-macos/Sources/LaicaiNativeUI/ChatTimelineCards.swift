// Session & auxiliary timeline cards extracted from ChatTimelineView.
import LaicaiNativeDomain
import LaicaiNativeFoundation
import SwiftUI

struct EmptyRunningThreadCard: View {
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
                        .accessibilityLabel("正在准备会话")
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

struct TaskHistoryFoldCard: View {
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
            .accessibilityLabel("展开早期步骤")
            .accessibilityHint("显示已折叠的全部 \(hiddenCount) 条步骤")
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

struct ThreadSummaryCard: View {
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

struct SessionStepCard: View {
    let step: TaskStep
    var live: LiveStreamSource? = nil

    var body: some View {
        switch step.kind {
        case .userInput:
            UserInputCard(text: step.text)
        case .textOutput:
            TextOutputCard(
                text: step.text,
                metrics: step.metrics,
                isRunning: step.metrics == nil && step.toolCallId == AppStore.streamingOutputID,
                live: step.toolCallId == AppStore.streamingOutputID ? live : nil)
        case .aiThinking:
            ThinkingCard(
                text: step.text,
                reasoningContent: step.reasoningContent,
                isRunning: false,
                live: step.toolCallId == AppStore.thinkingStreamID ? live : nil)
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

