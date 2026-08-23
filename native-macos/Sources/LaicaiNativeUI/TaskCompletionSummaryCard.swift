import AppKit
import LaicaiNativeDomain
import LaicaiNativeFoundation
import SwiftUI

// MARK: - Task Completion Summary Card

struct TaskCompletionSummaryCard: View {
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

    private var statusTitle: String {
        switch thread.status {
        case .completed: return "会话完成"
        case .cancelled: return "会话已暂停"
        case .waitingReview: return "等待审查"
        case .queued: return "排队中"
        case .running: return "处理中"
        case .failed: return "会话失败"
        }
    }

    private var statusIcon: String {
        switch thread.status {
        case .completed: return "checkmark.seal.fill"
        case .cancelled: return "pause.circle.fill"
        case .waitingReview: return "eye.circle.fill"
        case .queued: return "clock.fill"
        case .running: return "progress.indicator"
        case .failed: return "xmark.seal.fill"
        }
    }

    private var statusColor: Color {
        switch thread.status {
        case .completed: return Semantic.success
        case .cancelled, .queued: return TextGrade.muted
        case .waitingReview: return Semantic.warning
        case .running: return Brand.primary
        case .failed: return Semantic.error
        }
    }

    private var duration: String? {
        let interval = thread.updatedAt.timeIntervalSince(thread.createdAt)
        guard interval > 1 else { return nil }
        if interval < 60 { return "\(Int(interval))秒" }
        if interval < 3600 { return "\(Int(interval / 60))分\(Int(interval.truncatingRemainder(dividingBy: 60)))秒" }
        return "\(Int(interval / 3600))时\(Int((interval.truncatingRemainder(dividingBy: 3600)) / 60))分"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.medium) {
            // Header
            HStack(spacing: AppSpace.small) {
                Image(systemName: statusIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(statusColor)
                Text(statusTitle)
                    .font(AppFont.subheadline)
                    .foregroundStyle(statusColor)
                if let dur = duration {
                    Text("· \(dur)")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                }
                Spacer()
            }

            // Changed files
            if !writtenFiles.isEmpty {
                VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
                    HStack(spacing: AppSpace.extraSmall) {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(TextGrade.secondary)
                        Text("变更文件（\(writtenFiles.count)）")
                            .font(AppFont.captionMedium)
                            .foregroundStyle(TextGrade.secondary)
                    }
                    ForEach(writtenFiles.prefix(8), id: \.self) { path in
                        HStack(spacing: AppSpace.extraSmall) {
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
                .padding(AppSpace.small)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        .fill(SurfaceGrade.sunken.opacity(0.5))
                )
            }

            // Failed items
            if !failedSteps.isEmpty {
                VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
                    HStack(spacing: AppSpace.extraSmall) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Semantic.error)
                        Text("失败项（\(failedSteps.count)）")
                            .font(AppFont.captionMedium)
                            .foregroundStyle(Semantic.error)
                    }
                    ForEach(failedSteps.prefix(5), id: \.id) { step in
                        HStack(spacing: AppSpace.extraSmall) {
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
                .padding(AppSpace.small)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        .fill(Semantic.errorMuted.opacity(0.5))
                )
            }

            // Shell commands summary
            if !shellCommands.isEmpty {
                HStack(spacing: AppSpace.extraSmall) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                        .foregroundStyle(TextGrade.secondary)
                    Text("执行了 \(shellCommands.count) 条命令")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                }
            }

            if verifyCount > 0 {
                HStack(spacing: AppSpace.extraSmall) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 10))
                        .foregroundStyle(Semantic.success)
                    Text("验证了 \(verifyCount) 次")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                }
            }
        }
        .padding(AppSpace.large)
        .frame(maxWidth: 580, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(SurfaceGrade.card.opacity(0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
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

struct TaskRatingBar: View {
    @EnvironmentObject private var store: AppStore
    let threadID: UUID
    let currentRating: Int

    var body: some View {
        HStack(spacing: AppSpace.small) {
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
        .padding(.horizontal, AppSpace.medium)
        .padding(.vertical, AppSpace.extraSmall)
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
