import AppKit
import LaicaiNativeDomain
import LaicaiNativeFoundation
import SwiftUI

// MARK: - Task Summary Card

struct TaskStepCard: View {
    @EnvironmentObject private var store: AppStore
    let step: TaskStep
    let taskID: UUID
    let isRunning: Bool
    /// Read once by the parent timeline so this card's body never touches
    /// AppStore — otherwise every visible card re-renders on any state write.
    let showsDebugPanels: Bool
    /// Non-nil only while rendering a live streaming placeholder step.
    var live: LiveStreamSource? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let role = step.agentRole {
                agentRoleBadge(role)
            }
            stepContent
        }
        .contextMenu {
            Button {
                store.forkThread(id: taskID, fromStepID: step.id)
            } label: {
                Label("从此处分支", systemImage: "arrow.triangle.branch")
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step.kind {
        case .userInput:
            if isContinuationStrategy(step) {
                ContinuationStrategyBar(text: step.text)
            } else {
                UserInputCard(text: step.text)
            }
        case .aiThinking:
            // Collapsed aiThinking = orchestration audit / internal label that the user
            // should never see (continuation strategy, agent switch, completion check etc).
            // True model reasoning surfaces through non-collapsed steps with reasoningContent.
            if step.isCollapsed && (step.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                if showsDebugPanels {
                    OrchestrationDebugCard(text: step.text, label: "编排")
                } else {
                    EmptyView()
                }
            } else {
                ThinkingCard(
                    text: step.text,
                    reasoningContent: step.reasoningContent,
                    isRunning: isRunning,
                    live: step.toolCallId == AppStore.thinkingStreamID ? live : nil)
            }
        case .toolCall:
            if isRecoveryStep(step) {
                RecoveryCard(step: step)
            } else {
                ToolCallCard(step: step, taskID: taskID)
            }
        case .toolResult:
            if isRecoveryStep(step) {
                // Recovery results shown inline in RecoveryCard, skip duplicate
                EmptyView()
            } else if step.isCollapsed && !step.isFailure {
                if showsDebugPanels {
                    OrchestrationDebugCard(text: step.text, label: step.toolName ?? "工具结果")
                } else {
                    EmptyView()
                }
            } else {
                ToolResultCard(step: step, taskID: taskID)
            }
        case .textOutput:
            TextOutputCard(
                text: step.text,
                metrics: step.metrics,
                isRunning: isRunning && step.metrics == nil,
                live: step.toolCallId == AppStore.streamingOutputID ? live : nil)
        case .error:
            if !step.isFailure {
                PausedCard(step: step, taskID: taskID)
            } else {
                FailedCard(step: step, taskID: taskID)
            }
        case .reviewRequest: ReviewCard(step: step, taskID: taskID)
        case .reviewResult: ReviewResultCard(step: step)
        }
    }

    private func isRecoveryStep(_ step: TaskStep) -> Bool {
        (step.toolCallId ?? "").hasPrefix("call_recovery_") || step.text.hasPrefix("自动恢复")
    }

    private func agentRoleBadge(_ role: AgentRole) -> some View {
        HStack(spacing: 4) {
            Image(systemName: role.icon)
                .font(.system(size: 9, weight: .medium))
            Text(role.title)
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(Brand.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Brand.primary.opacity(0.08)))
        .padding(.bottom, 4)
    }
}

// MARK: - Continuation Strategy Detection

func isContinuationStrategy(_ step: TaskStep) -> Bool {
    guard step.kind == .userInput else { return false }
    let text = step.text
    return text.hasPrefix("继续执行这个会话")
        || text.hasPrefix("继续执行这个任务")
        || text == "继续执行"
}

// MARK: - Continuation Strategy Bar

struct ContinuationStrategyBar: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        HStack(spacing: AppSpace.small) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TextGrade.muted)

            if isExpanded {
                Text(text)
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.muted)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("接着上次进度继续")
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.muted)
                    .lineLimit(1)
            }

            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(TextGrade.ghost)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AppSpace.medium)
        .padding(.vertical, AppSpace.extraSmall)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                .fill(SurfaceGrade.sunken.opacity(0.72))
        )
    }
}

// MARK: - Step Cards

struct UserInputCard: View {
    let text: String
    private let previewLimit = 1_200

    var body: some View {
        HStack {
            Spacer(minLength: 100)

            Text(displayText)
                .font(AppFont.bubbleBody)
                .foregroundStyle(TextGrade.primary)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, AppSpace.medium + 2)
                .padding(.vertical, AppSpace.small + 2)
                .frame(maxWidth: 620, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        .fill(Semantic.userBubble)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        .strokeBorder(SurfaceGrade.hairline, lineWidth: 0.6)
                )
                .contextMenu {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        ToastCenter.shared.success("已复制")
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                }
        }
    }

    private var displayText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > previewLimit else { return trimmed }
        return String(trimmed.prefix(previewLimit)) + "\n\n… 共 \(trimmed.count) 字，已折叠"
    }
}

struct ThinkingCard: View {
    let text: String
    let reasoningContent: String?
    let isRunning: Bool
    /// Present while rendering the transient "__thinking_stream__" placeholder;
    /// reasoning then streams from StreamTextStore without touching AppState.
    var live: LiveStreamSource? = nil

    @State private var showReasoning = false
    var body: some View {
        HStack(alignment: .top, spacing: AppSpace.small) {
            ProgressGlyph(icon: "brain", color: Brand.purple, isActive: isRunning)

            VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
                HStack(spacing: AppSpace.extraSmall) {
                    Text(isRunning ? "思考中" : "已分析")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)

                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.7)
                    }

                    if let live {
                        LiveReasoningToggle(live: live, showReasoning: $showReasoning)
                    } else if hasReasoning {
                        Button {
                            showReasoning.toggle()
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: showReasoning ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 8, weight: .semibold))
                                Text(showReasoning ? "收起推理" : "查看推理")
                                    .font(AppFont.tiny)
                                Text("(\(reasoningTokenCount))")
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
                    }
                }

                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(text)
                        .font(AppFont.body)
                        .foregroundStyle(TextGrade.secondary)
                        .lineLimit(showReasoning ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if showReasoning {
                    if let live {
                        LiveReasoningBody(live: live)
                    } else if let reasoning = reasoningContent, !reasoning.isEmpty {
                        VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
                        Divider()
                            .background(Brand.purple.opacity(0.15))

                        ScrollView(.vertical, showsIndicators: true) {
                            Text(reasoningDisplayText(reasoning))
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
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var hasReasoning: Bool {
        guard let reasoning = reasoningContent else { return false }
        return !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var reasoningTokenCount: String {
        guard let reasoning = reasoningContent else { return "0" }
        let count = reasoning.count / 4  // rough token estimate
        if count > 1000 { return "\(count / 1000)k" }
        return "\(count)"
    }

    private func reasoningDisplayText(_ reasoning: String) -> String {
        reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ToolCallCard: View {
    @EnvironmentObject private var store: AppStore
    let step: TaskStep
    let taskID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
            HStack(spacing: AppSpace.small) {
                ProgressGlyph(icon: "wrench.and.screwdriver", color: step.isFailure ? Semantic.error : Semantic.toolCall)

                VStack(alignment: .leading, spacing: 2) {
                    Text(toolTitle)
                        .font(AppFont.captionMedium)
                        .foregroundStyle(step.isFailure ? Semantic.error : TextGrade.secondary)
                        .lineLimit(1)

                    Text(step.text)
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.ghost)
                        .lineLimit(1)

                    Text(toolReason)
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.ghost.opacity(0.82))
                        .lineLimit(1)
                }

                Spacer()

                if step.isCollapsible {
                    Button {
                        store.toggleStepCollapsed(taskID: taskID, stepID: step.id)
                    } label: {
                        Image(systemName: step.isCollapsed ? "chevron.down" : "chevron.up")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(TextGrade.muted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard step.isCollapsible else { return }
                store.toggleStepCollapsed(taskID: taskID, stepID: step.id)
            }

            if !step.isCollapsed, let params = step.toolParams, !params.isEmpty {
                VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
                    if let toolName = step.toolName {
                        HStack(spacing: AppSpace.small) {
                            Text("动作")
                                .font(AppFont.codeSmall)
                                .foregroundStyle(TextGrade.muted)
                            Text(toolName)
                                .font(AppFont.codeSmall)
                                .foregroundStyle(TextGrade.primary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, AppSpace.medium)
                        .padding(.vertical, 2)
                    }
                    HStack(spacing: AppSpace.small) {
                        Text("原因")
                            .font(AppFont.codeSmall)
                            .foregroundStyle(TextGrade.muted)
                        Text(toolReason)
                            .font(AppFont.codeSmall)
                            .foregroundStyle(TextGrade.secondary)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, AppSpace.medium)
                    .padding(.vertical, 2)
                    ForEach(Array(params.keys.sorted()), id: \.self) { key in
                        HStack(spacing: AppSpace.small) {
                            Text(key)
                                .font(AppFont.codeSmall)
                                .foregroundStyle(TextGrade.muted)
                            Text(params[key] ?? "")
                                .font(AppFont.codeSmall)
                                .foregroundStyle(TextGrade.primary)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, AppSpace.medium)
                        .padding(.vertical, 2)
                    }
                }
                .padding(.leading, 30)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
    }

    private var toolTitle: String {
        if let name = step.toolName, !name.isEmpty {
            let display = Self.friendlyToolName(name)
            return step.isFailure ? "\(display)失败" : display
        }
        return step.isFailure ? "执行失败" : "处理中"
    }

    private static let friendlyToolNames: [String: String] = [
        "workspace.index": "项目索引",
        "file.read": "读取文件",
        "file.write": "写入文件",
        "file.edit": "编辑文件",
        "diff.apply": "应用补丁",
        "verify.build": "验证构建",
        "code.search": "搜索代码",
        "shell.exec": "执行命令",
        "git": "查看历史",
        "web.search": "搜索网页",
        "web.fetch": "读取网页",
        "wiki.build": "生成知识页",
        "image.generate": "生成图片",
    ]

    static func friendlyToolName(_ name: String) -> String {
        friendlyToolNames[name] ?? name
    }

    private var toolReason: String {
        let params = step.toolParams
        switch step.toolName {
        case "workspace.index":
            return "建立项目索引"
        case "code.search":
            return queryReason(params, fallback: "搜索代码")
        case "file.read":
            return pathReason(params, verb: "读取", fallback: "读取文件")
        case "shell.exec":
            if let command = params?["command"] { return "执行 \(String(command.prefix(30)))" }
            return "执行命令"
        case "git":
            return "Git 操作"
        case "web.search":
            return queryReason(params, fallback: "联网搜索")
        case "web.fetch":
            if let url = params?["url"] { return "读取 \(String(url.prefix(40)))" }
            return "读取网页"
        case "file.write":
            return pathReason(params, verb: "写入", fallback: "写入文件")
        case "file.edit":
            return pathReason(params, verb: "编辑", fallback: "编辑文件")
        case "diff.apply":
            return pathReason(params, verb: "补丁", fallback: "应用补丁")
        case "verify.build":
            if let command = params?["command"] { return "验证 \(String(command.prefix(30)))" }
            return "验证构建"
        case "wiki.build":
            return "构建知识库页面"
        case "image.generate":
            if let prompt = params?["prompt"] { return "生成「\(String(prompt.prefix(30)))」" }
            return "生成图片"
        default:
            return step.toolName ?? "工具调用"
        }
    }

    private func queryReason(_ params: [String: String]?, fallback: String) -> String {
        guard let query = params?["query"] else { return fallback }
        return "搜索「\(String(query.prefix(30)))」"
    }

    private func pathReason(_ params: [String: String]?, verb: String, fallback: String) -> String {
        guard let path = params?["path"] ?? params?["fullPath"] else { return fallback }
        return "\(verb) \(pathDisplayName(path))"
    }

    private func pathDisplayName(_ path: String) -> String {
        String(path.suffix(from: path.lastIndex(of: "/") ?? path.startIndex))
    }
}

// MARK: - Recovery Card (auto-recovery visualization)

struct RecoveryCard: View {
    let step: TaskStep

    var body: some View {
        HStack(alignment: .top, spacing: AppSpace.small) {
            ZStack {
                Circle()
                    .fill(Semantic.warning.opacity(0.10))
                    .frame(width: 26, height: 26)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Semantic.warning)
            }
            .frame(width: 26)

            VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
                HStack(spacing: AppSpace.extraSmall) {
                    Text("已自动换一种方式继续")
                        .font(AppFont.captionMedium)
                        .foregroundStyle(Semantic.warning)

                    if step.isFailure {
                        Text("失败")
                            .font(AppFont.tiny)
                            .foregroundStyle(Semantic.error)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Semantic.errorMuted.opacity(0.4)))
                    } else {
                        Text("成功")
                            .font(AppFont.tiny)
                            .foregroundStyle(Semantic.success)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Semantic.success.opacity(0.12)))
                    }
                }

                HStack(spacing: AppSpace.extraSmall) {
                    if let original = originalTool, let fallback = fallbackTool {
                        Text(ToolCallCard.friendlyToolName(original))
                            .font(AppFont.codeSmall)
                            .foregroundStyle(Semantic.error.opacity(0.8))
                            .strikethrough()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(TextGrade.muted)
                        Text(ToolCallCard.friendlyToolName(fallback))
                            .font(AppFont.codeSmall)
                            .foregroundStyle(Semantic.success)
                    } else {
                        Text(step.text)
                            .font(AppFont.codeSmall)
                            .foregroundStyle(TextGrade.secondary)
                            .lineLimit(2)
                    }
                }

                if let path = step.toolParams?["path"] {
                    Text(String(path.suffix(from: path.lastIndex(of: "/") ?? path.startIndex)))
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.ghost)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, AppSpace.medium)
        .padding(.vertical, AppSpace.small)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(Semantic.warningMuted.opacity(0.20))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(Semantic.warning.opacity(0.12), lineWidth: 0.5)
        )
        .padding(.vertical, 2)
    }

    private var originalTool: String? {
        let text = step.text
        if text.contains("原工具") {
            // "自动恢复：xxx" or "原工具 xxx 失败后自动降级"
            if let range = text.range(of: "原工具 ") {
                let after = text[range.upperBound...]
                return String(after.prefix(while: { $0 != " " && $0 != "）" && $0 != ")" }))
            }
        }
        return nil
    }

    private var fallbackTool: String? {
        step.toolName
    }
}

struct TerminalOutputCard: View {
    let text: String
    let isFailure: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AppSpace.extraSmall) {
                Circle().fill(isFailure ? Semantic.error : Semantic.success).frame(width: 7, height: 7)
                Text(isFailure ? "命令执行失败" : "命令已完成")
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
                Spacer()
            }
            .padding(.horizontal, AppSpace.small)
            .padding(.vertical, AppSpace.extraSmall)
            .background(SurfaceGrade.elevated.opacity(0.45))

            Text(text.isEmpty ? "命令无输出" : (text.count > 1800 ? String(text.prefix(1800)) + "\n\n… 共 \(text.count) 字，已截断" : text))
                .font(AppFont.codeSmall)
                .foregroundStyle(isFailure ? Semantic.error : TextGrade.secondary)
                .lineLimit(isFailure ? 12 : 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppSpace.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(SurfaceGrade.card)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(SurfaceGrade.border.opacity(0.55), lineWidth: 0.6)
        )
    }
}

struct ProgressGlyph: View {
    let icon: String
    let color: Color
    var isActive: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(isActive ? 0.12 : 0.06))
                .frame(width: 24, height: 24)

            if isActive {
                Circle()
                    .strokeBorder(color.opacity(0.15), lineWidth: 0.5)
                    .frame(width: 24, height: 24)
            }

            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
        }
        .frame(width: 26)
    }
}

