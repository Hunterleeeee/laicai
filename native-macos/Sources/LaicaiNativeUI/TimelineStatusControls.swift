import AppKit
import LaicaiNativeDomain
import LaicaiNativeFoundation
import SwiftUI

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @EnvironmentObject private var store: AppStore
    let threadID: UUID
    @State private var pulsing = false
    @State private var now = Date()

    private var activityText: String {
        let text = store.liveActivity(for: threadID)
        return text.isEmpty ? "正在处理…" : text
    }

    private var elapsed: Int {
        guard let start = store.generationStartedAt(for: threadID) else { return 0 }
        return max(0, Int(now.timeIntervalSince(start)))
    }

    var body: some View {
        HStack(spacing: AppSpace.small) {
            HStack(spacing: AppSpace.small) {
                // Pulsing dot — the repeatForever animation runs on the render
                // server and never re-evaluates body, unlike the previous
                // 0.8s Timer.
                Circle()
                    .fill(Brand.primary)
                    .frame(width: 7, height: 7)
                    .scaleEffect(pulsing ? 0.7 : 1.0)
                    .opacity(pulsing ? 0.5 : 1.0)

                Text(activityText)
                    .font(AppFont.captionMedium)
                    .foregroundStyle(TextGrade.secondary)
                    .lineLimit(1)

                if elapsed > 0 {
                    Text(elapsedLabel)
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.ghost)
                }

                if let progress = store.estimatedProgress(for: threadID) {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Brand.primary)
                }
            }
            .padding(.horizontal, AppSpace.large)
            .padding(.vertical, AppSpace.small + 2)
            .background(
                Capsule()
                    .fill(SurfaceGrade.card)
                    .overlay(Capsule().strokeBorder(Brand.primary.opacity(0.12), lineWidth: 1))
            )
            .shadow(color: .black.opacity(0.035), radius: 3, y: 1)

            Spacer()
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
        // Single cancellable task replaces the two strongly-captured Timers;
        // SwiftUI cancels it automatically when the view disappears (including
        // LazyVStack recycling, where Timer-based cleanup was unreliable).
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                now = Date()
            }
        }
    }

    private var elapsedLabel: String {
        let elapsedSeconds = elapsed
        if elapsedSeconds < 60 { return "\(elapsedSeconds)s" }
        return "\(elapsedSeconds / 60)m\(elapsedSeconds % 60)s"
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
        HStack(spacing: AppSpace.medium) {
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
                HStack(spacing: AppSpace.extraSmall) {
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
                .padding(.horizontal, AppSpace.large)
                .padding(.vertical, AppSpace.small + 2)
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
                HStack(spacing: AppSpace.extraSmall) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("全部拒绝")
                        .font(AppFont.captionMedium)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, AppSpace.large)
                .padding(.vertical, AppSpace.small + 2)
                .background(Capsule().fill(Semantic.error))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AppSpace.large)
        .padding(.vertical, AppSpace.medium)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.extraLarge, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.extraLarge, style: .continuous)
                .strokeBorder(Semantic.warning.opacity(0.30), lineWidth: 1)
        )
        .padding(.horizontal, AppSpace.extraLarge)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
