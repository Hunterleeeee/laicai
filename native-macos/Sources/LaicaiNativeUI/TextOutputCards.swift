// Text output & live streaming observers extracted from TimelineCards.
import LaicaiNativeDomain
import LaicaiNativeFoundation
import SwiftUI

struct TextOutputCard: View {
    @EnvironmentObject private var store: AppStore
    let text: String
    let metrics: ResponseMetrics?
    var isRunning: Bool = false
    /// Present while rendering the transient streaming placeholder; the card
    /// then subscribes to StreamTextStore instead of AppState for token flushes.
    var live: LiveStreamSource? = nil
    @State private var showFullRunningOutput = false
    @State private var showFullCompletedOutput = false
    private let runningPreviewLimit = 2_400
    private let completedPreviewLimit = 2_200

    var body: some View {
        HStack(alignment: .top, spacing: AppSpace.small) {
            if isRunning || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ProgressGlyph(icon: "sparkles", color: Brand.primary, isActive: true)
            }

            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: AppSpace.small) {
                    if shouldShowHeader {
                        HStack(spacing: AppSpace.extraSmall) {
                            if isRunning || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(statusText)
                                    .font(AppFont.captionMedium)
                                    .foregroundStyle(TextGrade.muted)
                            }
                            if let metrics {
                                Text(metricsLine(metrics))
                                    .font(AppFont.tiny)
                                    .foregroundStyle(TextGrade.ghost)
                                    .lineLimit(1)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        if isRunning {
                            if let live {
                                LiveRunningOutput(live: live, showFull: $showFullRunningOutput)
                            } else {
                                AdaptiveMarkdownText(
                                    markdown: runningDisplayText,
                                    fontSize: 14,
                                    enablesTextSelection: false,
                                    forceFast: true,
                                    isStreaming: true
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)

                                if isRunningLong {
                                    Button {
                                        showFullRunningOutput.toggle()
                                    } label: {
                                        Text(showFullRunningOutput ? "收起流式预览" : "展开更多")
                                            .font(AppFont.captionMedium)
                                            .foregroundStyle(Brand.primary)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.top, AppSpace.extraSmall)
                                }
                            }
                        } else {
                            AdaptiveMarkdownText(
                                markdown: completedDisplayText,
                                fontSize: 14,
                                enablesTextSelection: true
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)

                            if isCompletedLong {
                                HStack(spacing: AppSpace.small) {
                                    Button {
                                        showFullCompletedOutput.toggle()
                                    } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: showFullCompletedOutput ? "rectangle.compress.vertical" : "text.alignleft")
                                                .font(.system(size: 10, weight: .semibold))
                                            Text(showFullCompletedOutput ? "收起全文" : "展开全文")
                                                .font(AppFont.captionMedium)
                                        }
                                        .foregroundStyle(Brand.primary)
                                    }
                                    .buttonStyle(.plain)

                                    Text("\(trimmedText.count) 字")
                                        .font(AppFont.tiny)
                                        .foregroundStyle(TextGrade.ghost)

                                    Spacer()
                                }
                                .padding(.top, AppSpace.small)
                            }
                        }

                        if isRunning && live == nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Brand.primary)
                                .frame(width: 2, height: 16)
                                .opacity(0.82)
                                .padding(.top, 2)
                        }
                    }
                }
                .padding(.horizontal, AppSpace.large)
                .padding(.vertical, AppSpace.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        .fill(SurfaceGrade.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        .strokeBorder(SurfaceGrade.hairline, lineWidth: 0.6)
                )
                .shadow(color: Color.black.opacity(0.018), radius: 2, y: 1)

            }
            .contextMenu {
                if !trimmedText.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        ToastCenter.shared.success("已复制")
                    } label: {
                        Label("复制全文", systemImage: "doc.on.doc")
                    }

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("```\n\(text)\n```", forType: .string)
                        ToastCenter.shared.success("已复制为代码块")
                    } label: {
                        Label("复制为代码块", systemImage: "chevron.left.forwardslash.chevron.right")
                    }

                    Divider()

                    Button {
                        let service =
                            NSSharingService(named: .composeEmail)
                            ?? NSSharingService(named: .composeMessage)
                        if let service {
                            service.perform(withItems: [text as NSString])
                        } else {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                            ToastCenter.shared.success("已复制，请粘贴分享")
                        }
                    } label: {
                        Label("分享…", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        saveToWiki(text)
                    } label: {
                        Label("存入 Wiki", systemImage: "book.closed")
                    }

                    Divider()

                    if let responseMetrics = metrics {
                        Button {
                        } label: {
                            Label(metricsLine(responseMetrics), systemImage: "gauge.with.dots.needle.33percent")
                        }
                        .disabled(true)
                    }
                }
            }
        }
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isRunningLong: Bool {
        trimmedText.count > runningPreviewLimit
    }

    private var isCompletedLong: Bool {
        !isRunning && trimmedText.count > completedPreviewLimit
    }

    private var runningDisplayText: String {
        guard isRunningLong, !showFullRunningOutput else { return trimmedText }
        let headCount = 800
        let tailCount = max(800, runningPreviewLimit - headCount)
        return "\(trimmedText.prefix(headCount))\n\n... 正在生成，已折叠中间内容以保持滚动流畅 ...\n\n\(trimmedText.suffix(tailCount))"
    }

    private var completedDisplayText: String {
        guard isCompletedLong, !showFullCompletedOutput else { return trimmedText }
        return "\(trimmedText.prefix(completedPreviewLimit))\n\n... 已折叠长回复以保持滚动流畅，点击“展开全文”查看全部 ..."
    }

    @MainActor private func saveToWiki(_ content: String) {
        let vaultSetting = store.state.settings.vaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = store.state.settings.workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let vault = vaultSetting.isEmpty ? workspace : vaultSetting
        guard !vault.isEmpty else {
            ToastCenter.shared.error("请先在设置中配置工作区或 Vault 路径")
            return
        }
        let dir = URL(fileURLWithPath: vault).appendingPathComponent("05 AI Outputs", isDirectory: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HHmmss"
        let fileName = "output-\(fmt.string(from: Date())).md"
        let fileURL = dir.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            ToastCenter.shared.success("已保存到 Wiki：\(fileName)")
        } catch {
            ToastCenter.shared.error("保存失败：\(error.localizedDescription)")
        }
    }

    private func metricsLine(_ metrics: ResponseMetrics) -> String {
        var parts: [String] = []
        if let thinking = metrics.thinkingDuration {
            parts.append("思考 \(formatSeconds(thinking))")
        }
        if let input = metrics.inputTokens {
            parts.append("入 \(input)")
        }
        if let output = metrics.outputTokens {
            parts.append("出 \(output)")
        }
        if let speed = metrics.tokensPerSecond, speed.isFinite {
            parts.append("\(String(format: "%.1f", speed)) 词元/秒")
        }
        return parts.joined(separator: " · ")
    }

    private func formatSeconds(_ value: TimeInterval) -> String {
        if value < 10 {
            return "\(String(format: "%.1f", value))s"
        }
        return "\(Int(value.rounded()))s"
    }

    private var statusText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "正在回复" }
        return isRunning ? "正在生成" : ""
    }

    private var shouldShowHeader: Bool {
        isRunning || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || metrics != nil
    }
}

// MARK: - Live Streaming Observers

/// Renders live streaming output for the transient text placeholder. This is
/// the only view in a timeline that re-renders on token flushes.
private struct LiveRunningOutput: View {
    @ObservedObject private var streams: StreamTextStore
    private let threadID: UUID
    @Binding private var showFull: Bool
    private let runningPreviewLimit = 2_400

    init(live: LiveStreamSource, showFull: Binding<Bool>) {
        self._streams = ObservedObject(wrappedValue: live.store)
        self.threadID = live.threadID
        self._showFull = showFull
    }

    var body: some View {
        let trimmed = streams.text(forThread: threadID).trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 0) {
            AdaptiveMarkdownText(
                markdown: displayText(for: trimmed),
                fontSize: 14,
                enablesTextSelection: false,
                forceFast: true,
                isStreaming: true
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)

            if trimmed.count > runningPreviewLimit {
                Button {
                    showFull.toggle()
                } label: {
                    Text(showFull ? "收起流式预览" : "展开更多")
                        .font(AppFont.captionMedium)
                        .foregroundStyle(Brand.primary)
                }
                .buttonStyle(.plain)
                .padding(.top, AppSpace.extraSmall)
            }

            if !trimmed.isEmpty {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Brand.primary)
                    .frame(width: 2, height: 16)
                    .opacity(0.82)
                    .padding(.top, 2)
            }
        }
    }

    private func displayText(for trimmed: String) -> String {
        guard trimmed.count > runningPreviewLimit, !showFull else { return trimmed }
        let headCount = 800
        let tailCount = max(800, runningPreviewLimit - headCount)
        return "\(trimmed.prefix(headCount))\n\n... 正在生成，已折叠中间内容以保持滚动流畅 ...\n\n\(trimmed.suffix(tailCount))"
    }
}

/// Reasoning toggle badge driven by live streaming reasoning content.
struct LiveReasoningToggle: View {
    @ObservedObject private var streams: StreamTextStore
    private let threadID: UUID
    @Binding private var showReasoning: Bool

    init(live: LiveStreamSource, showReasoning: Binding<Bool>) {
        self._streams = ObservedObject(wrappedValue: live.store)
        self.threadID = live.threadID
        self._showReasoning = showReasoning
    }

    var body: some View {
        let reasoning = streams.reasoning(forThread: threadID)
        guard !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AnyView(Color.clear.frame(width: 0, height: 0))
        }
        return AnyView(
            Button {
                showReasoning.toggle()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: showReasoning ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text(showReasoning ? "收起推理" : "查看推理")
                        .font(AppFont.tiny)
                    Text("(\(tokenCount(reasoning)))")
                        .font(AppFont.tiny)
                }
                .foregroundStyle(Brand.purple.opacity(0.72))
                .padding(.horizontal, AppSpace.small)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(Brand.purple.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
        )
    }

    private func tokenCount(_ reasoning: String) -> String {
        let count = reasoning.count / 4
        if count > 1000 { return "\(count / 1000)k" }
        return "\(count)"
    }
}

/// Expanded live reasoning body driven by StreamTextStore.
struct LiveReasoningBody: View {
    @ObservedObject private var streams: StreamTextStore
    private let threadID: UUID

    init(live: LiveStreamSource) {
        self._streams = ObservedObject(wrappedValue: live.store)
        self.threadID = live.threadID
    }

    var body: some View {
        let reasoning = streams.reasoning(forThread: threadID)
        VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
            Divider()
                .background(Brand.purple.opacity(0.15))

            ScrollView(.vertical, showsIndicators: true) {
                Text(reasoning.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(TextGrade.secondary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            .padding(AppSpace.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(Brand.purple.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .strokeBorder(Brand.purple.opacity(0.10), lineWidth: 0.5)
            )
        }
    }
}
