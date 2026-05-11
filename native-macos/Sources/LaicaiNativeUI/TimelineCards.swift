import SwiftUI
import LaicaiNativeDomain
import LaicaiNativeFoundation

// MARK: - Task Summary Card

struct TaskStepCard: View {
    @EnvironmentObject private var store: AppStore
    let step: TaskStep
    let taskID: UUID
    let isRunning: Bool

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
            if step.isCollapsed {
                if store.state.settings.showDebugPanels {
                    OrchestrationDebugCard(text: step.text, label: "编排")
                } else {
                    EmptyView()
                }
            } else {
                ThinkingCard(text: step.text, reasoningContent: step.reasoningContent, isRunning: isRunning)
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
                if store.state.settings.showDebugPanels {
                    OrchestrationDebugCard(text: step.text, label: step.toolName ?? "工具结果")
                } else {
                    EmptyView()
                }
            } else {
                ToolResultCard(step: step)
            }
        case .textOutput: TextOutputCard(text: step.text, metrics: step.metrics, isRunning: isRunning && step.metrics == nil)
        case .error:
            if step.recoverable || !step.isFailure {
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
    let t = step.text
    return t.hasPrefix("继续执行这个任务") || t == "继续执行"
}

// MARK: - Continuation Strategy Bar

struct ContinuationStrategyBar: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        HStack(spacing: AppSpace.sm) {
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
                Text("继续策略：沿用已读结果，不重复搜索")
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.muted)
                    .lineLimit(1)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(TextGrade.ghost)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AppSpace.md)
        .padding(.vertical, AppSpace.xs)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                .fill(SurfaceGrade.sunken.opacity(0.72))
        )
    }
}

// MARK: - Step Cards

struct UserInputCard: View {
    let text: String
    @State private var isHovered = false

    var body: some View {
        HStack {
            Spacer(minLength: 100)

            ZStack(alignment: .topTrailing) {
                Text(text)
                    .font(AppFont.bubbleBody)
                    .foregroundStyle(TextGrade.primary)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, AppSpace.lg)
                    .padding(.vertical, AppSpace.md)
                    .frame(maxWidth: 560, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                            .fill(Semantic.userBubble)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                            .strokeBorder(Brand.primary.opacity(0.15), lineWidth: 0.5)
                    )

                if isHovered {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        ToastCenter.shared.success("已复制")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(TextGrade.muted)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: AppRadius.xs, style: .continuous)
                                    .fill(SurfaceGrade.elevated)
                            )
                    }
                    .buttonStyle(.plain)
                    .offset(x: -6, y: 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .onHover { h in withAnimation(AppAnimation.quick) { isHovered = h } }
        }
    }
}

struct ThinkingCard: View {
    let text: String
    let reasoningContent: String?
    let isRunning: Bool

    @State private var showReasoning = true

    var body: some View {
        HStack(alignment: .top, spacing: AppSpace.sm) {
            ProgressGlyph(icon: "brain", color: Brand.purple, isActive: isRunning)

            VStack(alignment: .leading, spacing: AppSpace.xs) {
                HStack(spacing: AppSpace.xs) {
                    Text(isRunning ? "思考中" : "已分析")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)

                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.7)
                    }

                    if hasReasoning {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showReasoning.toggle()
                            }
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: showReasoning ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 8, weight: .semibold))
                                Text("推理过程")
                                    .font(AppFont.tiny)
                                Text("(\(reasoningTokenCount))")
                                    .font(AppFont.tiny)
                            }
                            .foregroundStyle(Brand.purple.opacity(0.72))
                            .padding(.horizontal, AppSpace.sm)
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

                if showReasoning, let reasoning = reasoningContent, !reasoning.isEmpty {
                    VStack(alignment: .leading, spacing: AppSpace.xs) {
                        Divider()
                            .background(Brand.purple.opacity(0.15))

                        ScrollViewReader { proxy in
                            ScrollView(.vertical, showsIndicators: true) {
                                Text(reasoning)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(TextGrade.secondary.opacity(0.8))
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                    .padding(AppSpace.sm)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id("reasoning_bottom")
                            }
                            .frame(maxHeight: 300)
                            .background(
                                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                                    .fill(Brand.purple.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                                    .strokeBorder(Brand.purple.opacity(0.10), lineWidth: 0.5)
                            )
                            .onChange(of: reasoning) { _ in
                                if isRunning {
                                    withAnimation(.easeOut(duration: 0.1)) {
                                        proxy.scrollTo("reasoning_bottom", anchor: .bottom)
                                    }
                                }
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var hasReasoning: Bool {
        guard let r = reasoningContent else { return false }
        return !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var reasoningTokenCount: String {
        guard let r = reasoningContent else { return "0" }
        let count = r.count / 4  // rough token estimate
        if count > 1000 { return "\(count / 1000)k tokens" }
        return "\(count) tokens"
    }
}

struct ToolCallCard: View {
    @EnvironmentObject private var store: AppStore
    let step: TaskStep
    let taskID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.xs) {
            HStack(spacing: AppSpace.sm) {
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
                VStack(alignment: .leading, spacing: AppSpace.xs) {
                    if let toolName = step.toolName {
                        HStack(spacing: AppSpace.sm) {
                            Text("动作")
                                .font(AppFont.codeSmall)
                                .foregroundStyle(TextGrade.muted)
                            Text(toolName)
                                .font(AppFont.codeSmall)
                                .foregroundStyle(TextGrade.primary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, AppSpace.md)
                        .padding(.vertical, 2)
                    }
                    HStack(spacing: AppSpace.sm) {
                        Text("原因")
                            .font(AppFont.codeSmall)
                            .foregroundStyle(TextGrade.muted)
                        Text(toolReason)
                            .font(AppFont.codeSmall)
                            .foregroundStyle(TextGrade.secondary)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, AppSpace.md)
                    .padding(.vertical, 2)
                    ForEach(Array(params.keys.sorted()), id: \.self) { key in
                        HStack(spacing: AppSpace.sm) {
                            Text(key)
                                .font(AppFont.codeSmall)
                                .foregroundStyle(TextGrade.muted)
                            Text(params[key] ?? "")
                                .font(AppFont.codeSmall)
                                .foregroundStyle(TextGrade.primary)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, AppSpace.md)
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
            return step.isFailure ? "\(display) 失败" : "调用 \(display)"
        }
        return step.isFailure ? "工具失败" : "调用工具"
    }

    static func friendlyToolName(_ name: String) -> String {
        switch name {
        case "workspace.index": return "项目索引"
        case "file.read": return "读取文件"
        case "file.write": return "写入文件"
        case "code.search": return "搜索代码"
        case "shell.exec": return "执行命令"
        case "git": return "查看历史"
        case "web.search": return "搜索网页"
        case "web.fetch": return "读取网页"
        case "wiki.build": return "生成知识页"
        case "image.generate": return "生成图片"
        default: return name
        }
    }

    private var toolReason: String {
        let params = step.toolParams
        switch step.toolName {
        case "workspace.index":
            return "建立项目索引"
        case "code.search":
            if let q = params?["query"] { return "搜索「\(String(q.prefix(30)))」" }
            return "搜索代码"
        case "file.read":
            if let p = params?["path"] ?? params?["fullPath"] { return "读取 \(String(p.suffix(from: p.lastIndex(of: "/") ?? p.startIndex)))" }
            return "读取文件"
        case "shell.exec":
            if let cmd = params?["command"] { return "执行 \(String(cmd.prefix(30)))" }
            return "执行命令"
        case "git":
            return "Git 操作"
        case "web.search":
            if let q = params?["query"] { return "搜索「\(String(q.prefix(30)))」" }
            return "联网搜索"
        case "web.fetch":
            if let url = params?["url"] { return "读取 \(String(url.prefix(40)))" }
            return "读取网页"
        case "file.write":
            if let p = params?["path"] ?? params?["fullPath"] { return "写入 \(String(p.suffix(from: p.lastIndex(of: "/") ?? p.startIndex)))" }
            return "写入文件"
        case "wiki.build":
            return "构建知识库页面"
        case "image.generate":
            if let p = params?["prompt"] { return "生成「\(String(p.prefix(30)))」" }
            return "生成图片"
        default:
            return step.toolName ?? "工具调用"
        }
    }
}

struct ToolResultCard: View {
    @EnvironmentObject private var store: AppStore
    let step: TaskStep

    var body: some View {
        HStack(alignment: .top, spacing: AppSpace.sm) {
            ProgressGlyph(icon: step.isFailure ? "xmark" : "checkmark", color: step.isFailure ? Semantic.error : Semantic.success)

            VStack(alignment: .leading, spacing: AppSpace.xs) {
                if isTerminalOutput {
                    TerminalOutputCard(text: step.text, isFailure: step.isFailure)
                } else if !step.isCollapsed {
                    toolTextView
                } else {
                    Text(step.isFailure ? String(step.text.prefix(90)) : "工具结果已折叠")
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.ghost)
                        .lineLimit(1)
                }

                // Quick retry on failure
                if step.isFailure {
                    Button {
                        store.retryLastMessage()
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(AppFont.tiny)
                            .foregroundStyle(Brand.primary)
                            .padding(.horizontal, AppSpace.sm)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Brand.primary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var isTerminalOutput: Bool {
        ["shell.exec", "verify.build"].contains(step.toolName ?? "")
    }

    private var displayText: String {
        let maxLen = 2000
        if step.text.count <= maxLen { return step.text }
        return String(step.text.prefix(maxLen)) + "\n\n… 共 \(step.text.count) 字，已截断显示"
    }

    private var toolTextView: some View {
        Text(displayText)
            .font(AppFont.codeSmall)
            .foregroundStyle(step.isFailure ? Semantic.error : TextGrade.muted)
            .textSelection(.enabled)
            .lineLimit(step.isFailure ? 6 : 4)
            .padding(.horizontal, AppSpace.sm)
            .padding(.vertical, AppSpace.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                    .fill(SurfaceGrade.sunken.opacity(0.34))
            )
    }
}

// MARK: - Recovery Card (auto-recovery visualization)

struct RecoveryCard: View {
    let step: TaskStep

    var body: some View {
        HStack(alignment: .top, spacing: AppSpace.sm) {
            ZStack {
                Circle()
                    .fill(Semantic.warning.opacity(0.10))
                    .frame(width: 26, height: 26)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Semantic.warning)
            }
            .frame(width: 26)

            VStack(alignment: .leading, spacing: AppSpace.xs) {
                HStack(spacing: AppSpace.xs) {
                    Text("编排层自动恢复")
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

                HStack(spacing: AppSpace.xs) {
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
        .padding(.horizontal, AppSpace.md)
        .padding(.vertical, AppSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(Semantic.warningMuted.opacity(0.20))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
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
            HStack(spacing: AppSpace.xs) {
                Circle().fill(isFailure ? Semantic.error : Semantic.success).frame(width: 7, height: 7)
                Text(isFailure ? "Terminal · failed" : "Terminal · completed")
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
                Spacer()
            }
            .padding(.horizontal, AppSpace.sm)
            .padding(.vertical, AppSpace.xs)
            .background(SurfaceGrade.elevated.opacity(0.45))

            ScrollView {
                Text(text.isEmpty ? "命令无输出" : (text.count > 3000 ? String(text.prefix(3000)) + "\n\n… 共 \(text.count) 字，已截断" : text))
                    .font(AppFont.codeSmall)
                    .foregroundStyle(isFailure ? Semantic.error : TextGrade.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppSpace.sm)
            }
            .frame(maxHeight: isFailure ? 260 : 200)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(Color(hex: "0F172A"))
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(SurfaceGrade.border.opacity(0.4), lineWidth: 0.5)
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

struct TextOutputCard: View {
    let text: String
    let metrics: ResponseMetrics?
    var isRunning: Bool = false
    @State private var cursorVisible = true
    @State private var isHovered = false
    @State private var showFullRunningOutput = false
    private let runningPreviewLimit = 6_000

    var body: some View {
        HStack(alignment: .top, spacing: AppSpace.sm) {
            if isRunning || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ProgressGlyph(icon: "sparkles", color: Brand.primary, isActive: true)
            }

            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: AppSpace.sm) {
                    if shouldShowHeader {
                        HStack(spacing: AppSpace.xs) {
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
                            Text(runningDisplayText)
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(TextGrade.primary)
                                .lineSpacing(6)
                                .textSelection(.disabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
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
                                .padding(.top, AppSpace.xs)
                            }
                        } else {
                            MarkdownText(text, fontSize: 14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if isRunning && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Brand.primary)
                                .frame(width: 2, height: 16)
                                .opacity(cursorVisible ? 1 : 0)
                                .onAppear {
                                    withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                                        cursorVisible = false
                                    }
                                }
                                .padding(.top, 2)
                        }
                    }
                }
                .padding(.horizontal, AppSpace.lg)
                .padding(.vertical, AppSpace.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                        .fill(SurfaceGrade.card.opacity(0.4))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                        .strokeBorder(SurfaceGrade.border.opacity(0.3), lineWidth: 0.5)
                )

                if isHovered && !isRunning && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        ToastCenter.shared.success("已复制")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(TextGrade.muted)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                                    .fill(SurfaceGrade.elevated.opacity(0.92))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                                    .strokeBorder(SurfaceGrade.divider, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .offset(x: -6, y: 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.12), value: isHovered)
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
                        let service = NSSharingService(named: .composeEmail)
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

                    if let m = metrics {
                        Button {} label: {
                            Label(metricsLine(m), systemImage: "gauge.with.dots.needle.33percent")
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

    private var runningDisplayText: String {
        guard isRunningLong, !showFullRunningOutput else { return trimmedText }
        let headCount = 1_800
        let tailCount = max(1_800, runningPreviewLimit - headCount)
        return "\(trimmedText.prefix(headCount))\n\n... 正在生成，已折叠中间内容以保持滚动流畅 ...\n\n\(trimmedText.suffix(tailCount))"
    }

    @MainActor private func saveToWiki(_ content: String) {
        let vault = UserDefaults.standard.string(forKey: "vaultPath") ?? ""
        guard !vault.isEmpty else {
            ToastCenter.shared.error("请先在设置中配置 Vault 路径")
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
            ToastCenter.shared.success("已保存到 Wiki")
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

// MARK: - Paused Card (soft interruption / recoverable)

struct PausedCard: View {
    @EnvironmentObject private var store: AppStore
    let step: TaskStep
    let taskID: UUID

    var body: some View {
        HStack(alignment: .top, spacing: AppSpace.sm) {
            AvatarBadge(icon: "pause.circle.fill", color: Semantic.warning)

            VStack(alignment: .leading, spacing: AppSpace.xs) {
                Text("已暂停，可继续")
                    .font(AppFont.captionMedium)
                    .foregroundStyle(Semantic.warning)

                Text(diagnosisText)
                    .font(AppFont.body)
                    .foregroundStyle(TextGrade.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                HStack(spacing: AppSpace.sm) {
                    Button {
                        if step.retryAction == "继续执行" {
                            store.continueTask()
                        } else {
                            store.retryLastMessage()
                        }
                    } label: {
                        Label("继续任务", systemImage: "play.fill")
                            .font(AppFont.captionMedium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, AppSpace.md)
                            .padding(.vertical, AppSpace.sm)
                            .background(Capsule().fill(Brand.primary))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, AppSpace.lg)
            .padding(.vertical, AppSpace.md)
            .frame(maxWidth: 560, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .fill(Semantic.warningMuted.opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .strokeBorder(Semantic.warning.opacity(0.15), lineWidth: 0.5)
            )

            Spacer()
        }
    }

    private var diagnosisText: String {
        step.text.replacingOccurrences(of: "已自动标记为已取消", with: "已自动暂停")
    }
}

// MARK: - Failed Card (hard failure / non-recoverable)

struct FailedCard: View {
    @EnvironmentObject private var store: AppStore
    let step: TaskStep
    let taskID: UUID

    var body: some View {
        HStack(alignment: .top, spacing: AppSpace.sm) {
            AvatarBadge(icon: "exclamationmark.triangle.fill", color: Semantic.error)

            VStack(alignment: .leading, spacing: AppSpace.xs) {
                Text(failureTitle)
                    .font(AppFont.captionMedium)
                    .foregroundStyle(Semantic.error)

                Text(step.text)
                    .font(AppFont.body)
                    .foregroundStyle(TextGrade.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                HStack(spacing: AppSpace.sm) {
                    Button {
                        store.retryLastMessage()
                    } label: {
                        Label("重试一次", systemImage: "arrow.clockwise")
                            .font(AppFont.captionMedium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, AppSpace.md)
                            .padding(.vertical, AppSpace.sm)
                            .background(Capsule().fill(Brand.primary))
                    }
                    .buttonStyle(.plain)

                    if step.text.contains("鉴权") || step.text.contains("401") || step.text.contains("API key") || step.text.contains("超时") {
                        Button {
                            NotificationCenter.default.post(name: .init("laicaiOpenSettings"), object: nil)
                        } label: {
                            Label(step.text.contains("超时") ? "调整超时" : "检查模型配置", systemImage: "gearshape")
                                .font(AppFont.captionMedium)
                                .foregroundStyle(Semantic.error)
                                .padding(.horizontal, AppSpace.md)
                                .padding(.vertical, AppSpace.sm)
                                .background(Capsule().fill(Semantic.errorMuted.opacity(0.50)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, AppSpace.lg)
            .padding(.vertical, AppSpace.md)
            .frame(maxWidth: 560, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .fill(Semantic.errorMuted.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .strokeBorder(Semantic.error.opacity(0.15), lineWidth: 0.5)
            )

            Spacer()
        }
    }

    private var failureTitle: String {
        if step.text.contains("超时") { return "模型请求超时" }
        if step.text.contains("鉴权") || step.text.contains("401") || step.text.contains("API key") { return "模型鉴权失败" }
        return "失败，需处理"
    }
}

struct ReviewCard: View {
    @EnvironmentObject private var store: AppStore
    let step: TaskStep
    let taskID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            HStack(spacing: AppSpace.sm) {
                Image(systemName: "eye.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Semantic.warning)

                Text("需要审查")
                    .font(AppFont.subheadline)
                    .foregroundStyle(Semantic.warning)

                Spacer()
            }

            Text(step.text)
                .font(AppFont.body)
                .foregroundStyle(TextGrade.primary)

            if let filePath = step.diffFilePath {
                VStack(alignment: .leading, spacing: AppSpace.xs) {
                    reviewInfoRow(icon: "doc.text", label: "文件", value: filePath)
                    reviewInfoRow(icon: "shield", label: "风险", value: riskLabel(for: filePath))
                    if let added = step.toolParams?["addedLines"], let removed = step.toolParams?["removedLines"] {
                        reviewInfoRow(icon: "plus.forwardslash.minus", label: "变更", value: "+\(added) -\(removed) 行")
                    }
                }
                .padding(AppSpace.sm)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                        .fill(SurfaceGrade.card.opacity(0.65))
                )
            }

            if let hunks = step.diffHunks, !hunks.isEmpty {
                VStack(alignment: .leading, spacing: AppSpace.sm) {
                    ForEach(hunks) { hunk in
                        HunkCard(hunk: hunk, stepID: step.id, taskID: taskID, allDecided: step.approved != nil)
                    }
                }
            } else if let filePath = step.diffFilePath,
               let old = step.diffOldContent,
               let new = step.diffNewContent {
                DiffPreviewCard(filePath: filePath, oldContent: old, newContent: new)
            }

            if step.approved == nil && (step.diffHunks == nil || step.diffHunks?.isEmpty == true) {
                HStack(spacing: AppSpace.md) {
                    Button {
                        store.approveReview(taskID: taskID, stepID: step.id)
                    } label: {
                        Label("批准", systemImage: "checkmark")
                            .font(AppFont.captionMedium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, AppSpace.lg)
                            .padding(.vertical, AppSpace.sm + 2)
                            .background(Capsule().fill(Semantic.success))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("y", modifiers: .command)

                    Button {
                        store.rejectReview(taskID: taskID, stepID: step.id)
                    } label: {
                        Label("拒绝", systemImage: "xmark")
                            .font(AppFont.captionMedium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, AppSpace.lg)
                            .padding(.vertical, AppSpace.sm + 2)
                            .background(Capsule().fill(Semantic.error))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("n", modifiers: .command)

                    Button {
                        copyReviewPatch()
                    } label: {
                        Label("复制 diff", systemImage: "doc.on.doc")
                            .font(AppFont.captionMedium)
                            .foregroundStyle(TextGrade.secondary)
                            .padding(.horizontal, AppSpace.lg)
                            .padding(.vertical, AppSpace.sm + 2)
                            .background(Capsule().fill(SurfaceGrade.elevated.opacity(0.78)))
                            .overlay(Capsule().strokeBorder(SurfaceGrade.divider, lineWidth: 0.7))
                    }
                    .buttonStyle(.plain)
                }
            } else if step.approved == nil && step.diffHunks != nil {
                HStack(spacing: AppSpace.sm) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(TextGrade.muted)
                    Text("逐个审查上方每个 hunk，全部决定后自动应用")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                }
            } else {
                HStack(spacing: AppSpace.sm) {
                    HStack(spacing: AppSpace.xs) {
                        Image(systemName: step.approved == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(step.approved == true ? Semantic.success : Semantic.error)
                        Text(step.approved == true ? "已批准" : "已拒绝")
                            .font(AppFont.captionMedium)
                            .foregroundStyle(step.approved == true ? Semantic.success : Semantic.error)
                    }

                    if step.approved == true {
                        Button {
                            store.rollbackApprovedWrite(taskID: taskID, stepID: step.id)
                        } label: {
                            Label("回滚此变更", systemImage: "arrow.uturn.backward")
                                .font(AppFont.captionMedium)
                                .foregroundStyle(TextGrade.secondary)
                                .padding(.horizontal, AppSpace.md)
                                .padding(.vertical, AppSpace.xs + 1)
                                .background(Capsule().fill(SurfaceGrade.elevated.opacity(0.75)))
                                .overlay(Capsule().strokeBorder(SurfaceGrade.divider, lineWidth: 0.7))
                        }
                        .buttonStyle(.plain)
                        .help("回滚此步骤的文件变更")
                    }
                }
            }
        }
        .padding(AppSpace.lg)
        .frame(maxWidth: 580, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .fill(Semantic.warningMuted)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                .strokeBorder(Semantic.warning.opacity(0.25), lineWidth: 1)
        )
    }

    private func reviewInfoRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: AppSpace.sm) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Semantic.warning)
                .frame(width: 14)
            Text(label)
                .font(AppFont.tiny)
                .foregroundStyle(TextGrade.muted)
                .frame(width: 32, alignment: .leading)
            Text(value)
                .font(AppFont.caption)
                .foregroundStyle(TextGrade.secondary)
                .lineLimit(1)
            Spacer()
        }
    }

    private func riskLabel(for path: String) -> String {
        if !SandboxPolicy().isPathAllowed(path) {
            return "敏感路径，将被拦截"
        }
        return "批准后才会写入磁盘"
    }

    private func copyReviewPatch() {
        var lines: [String] = []
        lines.append("文件：\(step.diffFilePath ?? "文件变更")")
        lines.append("")
        if let old = step.diffOldContent, let new = step.diffNewContent {
            lines.append(Self.simpleDiff(old: old, new: new))
        } else {
            lines.append(step.text)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        ToastCenter.shared.success("已复制 diff")
    }

    static func simpleDiff(old: String, new: String) -> String {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        var result: [String] = []

        var idx = 0
        while idx < max(oldLines.count, newLines.count) {
            let inOld = idx < oldLines.count
            let inNew = idx < newLines.count

            if inOld && inNew && oldLines[idx] == newLines[idx] {
                result.append("  \(oldLines[idx])")
                idx += 1
            } else {
                let hunkStart = max(0, idx - 3)
                if hunkStart > 0 && hunkStart < idx {
                    let oldStart = hunkStart + 1
                    let newStart = hunkStart + 1
                    result.append("@@ -\(oldStart),\(idx - hunkStart + 1) +\(newStart),\(idx - hunkStart + 1) @@")
                }

                while idx < oldLines.count && (idx >= newLines.count || oldLines[idx] != newLines[min(idx, newLines.count - 1)]) {
                    if idx < newLines.count && oldLines[idx] == newLines[idx] { break }
                    result.append("- \(oldLines[idx])")
                    idx += 1
                    if idx >= oldLines.count { break }
                }
                let addedIdx = idx
                while addedIdx < newLines.count && (addedIdx >= oldLines.count || oldLines[min(addedIdx, oldLines.count - 1)] != newLines[addedIdx]) {
                    if addedIdx < oldLines.count && oldLines[addedIdx] == newLines[addedIdx] { break }
                    result.append("+ \(newLines[addedIdx])")
                    idx = addedIdx + 1
                    break
                }
                if idx < newLines.count {
                    for j in idx..<newLines.count {
                        if j < oldLines.count && oldLines[j] == newLines[j] { break }
                        result.append("+ \(newLines[j])")
                    }
                }
                idx = max(idx, min(oldLines.count, newLines.count))
                while idx < oldLines.count && idx < newLines.count && oldLines[idx] == newLines[idx] {
                    idx += 1
                }
            }
        }

        if result.isEmpty && (!old.isEmpty || !new.isEmpty) {
            result = []
            for line in oldLines { result.append("- \(line)") }
            for line in newLines { result.append("+ \(line)") }
        }

        return result.joined(separator: "\n")
    }
}

struct ReviewResultCard: View {
    let step: TaskStep

    var body: some View {
        HStack(spacing: AppSpace.xs) {
            Image(systemName: step.approved == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(step.approved == true ? Semantic.success : Semantic.error)

            Text(step.text.isEmpty ? (step.approved == true ? "已批准" : "已拒绝") : step.text)
                .font(AppFont.captionMedium)
                .foregroundStyle(step.approved == true ? Semantic.success : Semantic.error)
        }
        .padding(.horizontal, AppSpace.md)
        .padding(.vertical, AppSpace.sm)
        .background(
            Capsule()
                .fill((step.approved == true ? Semantic.success : Semantic.error).opacity(0.1))
        )
    }
}

// MARK: - Avatar Badge

struct AvatarBadge: View {
    let icon: String
    let color: Color

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 22, height: 22)
            .background(
                Circle()
                    .fill(color.opacity(0.08))
            )
    }
}

// MARK: - Hunk Card

struct HunkCard: View {
    @EnvironmentObject private var store: AppStore
    let hunk: DiffHunk
    let stepID: UUID
    let taskID: UUID
    let allDecided: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.xs) {
            HStack(spacing: AppSpace.sm) {
                Image(systemName: "number")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Brand.primary)
                Text(hunk.summary)
                    .font(AppFont.captionMedium)
                    .foregroundStyle(TextGrade.primary)
                    .lineLimit(1)
                Spacer()
                if let approved = hunk.approved {
                    Image(systemName: approved ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(approved ? Semantic.success : Semantic.error)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(hunkDiffLines, id: \.offset) { item in
                    HStack(spacing: 0) {
                        Text(item.element.prefix == "+" ? "+" : item.element.prefix == "-" ? "-" : " ")
                            .font(AppFont.codeSmall)
                            .foregroundStyle(hunkLineColor(item.element.prefix))
                            .frame(width: 14)
                        Text(item.element.text)
                            .font(AppFont.codeSmall)
                            .foregroundStyle(hunkLineTextColor(item.element.prefix))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, AppSpace.sm)
                    .padding(.vertical, 1)
                    .background(hunkLineBackground(item.element.prefix))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                    .strokeBorder(SurfaceGrade.divider, lineWidth: 0.5)
            )

            if hunk.approved == nil && !allDecided {
                HStack(spacing: AppSpace.sm) {
                    Button {
                        store.approveHunk(taskID: taskID, stepID: stepID, hunkID: hunk.id)
                    } label: {
                        Label("接受", systemImage: "checkmark")
                            .font(AppFont.tiny)
                            .foregroundStyle(.white)
                            .padding(.horizontal, AppSpace.md)
                            .padding(.vertical, AppSpace.xs)
                            .background(Capsule().fill(Semantic.success))
                    }
                    .buttonStyle(.plain)

                    Button {
                        store.rejectHunk(taskID: taskID, stepID: stepID, hunkID: hunk.id)
                    } label: {
                        Label("拒绝", systemImage: "xmark")
                            .font(AppFont.tiny)
                            .foregroundStyle(.white)
                            .padding(.horizontal, AppSpace.md)
                            .padding(.vertical, AppSpace.xs)
                            .background(Capsule().fill(Semantic.error))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(AppSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(SurfaceGrade.card.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(hunk.approved == true ? Semantic.success.opacity(0.3) : hunk.approved == false ? Semantic.error.opacity(0.3) : SurfaceGrade.divider, lineWidth: 0.7)
        )
    }

    private struct HunkLine {
        let prefix: String
        let text: String
    }

    private var hunkDiffLines: [EnumeratedSequence<[HunkLine]>.Element] {
        let oldLines = hunk.oldText.components(separatedBy: "\n")
        let newLines = hunk.newText.components(separatedBy: "\n")
        var lines: [HunkLine] = []
        for line in oldLines {
            lines.append(HunkLine(prefix: "-", text: line))
        }
        for line in newLines {
            lines.append(HunkLine(prefix: "+", text: line))
        }
        return Array(lines.enumerated())
    }

    private func hunkLineColor(_ prefix: String) -> Color {
        prefix == "+" ? Semantic.success : prefix == "-" ? Semantic.error : TextGrade.ghost
    }
    private func hunkLineTextColor(_ prefix: String) -> Color {
        prefix == "+" ? Semantic.success : prefix == "-" ? Semantic.error : TextGrade.secondary
    }
    private func hunkLineBackground(_ prefix: String) -> Color {
        prefix == "+" ? Semantic.success.opacity(0.08) : prefix == "-" ? Semantic.error.opacity(0.08) : Color.clear
    }
}

// MARK: - Diff Preview Card

struct DiffPreviewCard: View {
    let filePath: String
    let oldContent: String
    let newContent: String

    @State private var isSideBySide = false
    @State private var isExpanded = false

    private var diffLines: [NumberedDiffLine] {
        computeNumberedDiff()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            diffHeader
            if isSideBySide {
                sideBySideView
            } else {
                unifiedView
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(SurfaceGrade.divider, lineWidth: 0.5)
        )
    }

    // MARK: - Header

    private var diffHeader: some View {
        HStack {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(TextGrade.muted)
            Text(filePath)
                .font(AppFont.codeSmall)
                .foregroundStyle(TextGrade.secondary)
                .lineLimit(1)

            Spacer()

            let stats = diffStats
            HStack(spacing: AppSpace.xs) {
                if stats.added > 0 {
                    Text("+\(stats.added)")
                        .font(AppFont.tiny)
                        .foregroundStyle(Semantic.success)
                }
                if stats.removed > 0 {
                    Text("-\(stats.removed)")
                        .font(AppFont.tiny)
                        .foregroundStyle(Semantic.error)
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isSideBySide.toggle() }
            } label: {
                Image(systemName: isSideBySide ? "rectangle.split.1x2" : "rectangle.split.2x1")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(TextGrade.muted)
            }
            .buttonStyle(.plain)
            .help(isSideBySide ? "统一视图" : "并排视图")

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(TextGrade.muted)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "收起" : "展开")
        }
        .padding(.horizontal, AppSpace.md)
        .padding(.vertical, AppSpace.sm)
        .background(SurfaceGrade.elevated.opacity(0.5))
    }

    // MARK: - Unified View

    private var unifiedView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(indexedDiffLines.enumerated()), id: \.offset) { _, entry in
                    let line = entry.line
                    HStack(spacing: 0) {
                        Text(line.oldNum.map { "\($0)" } ?? "")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(TextGrade.ghost)
                            .frame(width: 28, alignment: .trailing)

                        Text(line.newNum.map { "\($0)" } ?? "")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(TextGrade.ghost)
                            .frame(width: 28, alignment: .trailing)

                        Text(line.type == .added ? "+" : line.type == .removed ? "-" : " ")
                            .font(AppFont.codeSmall)
                            .foregroundStyle(lineColor(line.type))
                            .frame(width: 14)

                        // Word-level highlight for changed lines
                        if let pairedContent = entry.pairedContent, line.type != .context {
                            inlineHighlightedText(original: line.content, paired: pairedContent, type: line.type)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            syntaxColoredText(line.content, fileExtension: fileExtension)
                                .font(AppFont.codeSmall)
                                .foregroundStyle(lineTextColor(line.type))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, AppSpace.sm)
                    .padding(.vertical, 1.5)
                    .background(lineBackground(line.type))
                }
            }
        }
        .frame(maxHeight: isExpanded ? 600 : 240)
    }

    /// Pairs removed/added lines to enable word-level diff highlighting
    private var indexedDiffLines: [(line: NumberedDiffLine, pairedContent: String?)] {
        let lines = diffLines
        var result: [(line: NumberedDiffLine, pairedContent: String?)] = []
        var i = 0
        while i < lines.count {
            if lines[i].type == .removed && i + 1 < lines.count && lines[i + 1].type == .added {
                result.append((line: lines[i], pairedContent: lines[i + 1].content))
                result.append((line: lines[i + 1], pairedContent: lines[i].content))
                i += 2
            } else {
                result.append((line: lines[i], pairedContent: nil))
                i += 1
            }
        }
        return result
    }

    /// Inline word-level highlighting using AttributedString
    private func inlineHighlightedText(original: String, paired: String, type: DiffLineType) -> some View {
        let origWords = tokenize(original)
        let pairWords = tokenize(paired)
        let changedSet = wordDiffIndices(from: origWords, to: pairWords)

        let highlightColor: Color = type == .added ? Semantic.success : Semantic.error
        let baseColor: Color = lineTextColor(type)

        return HStack(spacing: 0) {
            ForEach(Array(origWords.enumerated()), id: \.offset) { idx, word in
                if changedSet.contains(idx) {
                    Text(word)
                        .font(AppFont.codeSmall)
                        .foregroundStyle(highlightColor)
                        .background(highlightColor.opacity(0.18))
                } else {
                    Text(word)
                        .font(AppFont.codeSmall)
                        .foregroundStyle(baseColor)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Simple tokenizer that preserves whitespace as separate tokens
    private func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inWhitespace = false
        for ch in text {
            let isWS = ch == " " || ch == "\t"
            if isWS != inWhitespace && !current.isEmpty {
                tokens.append(current)
                current = ""
            }
            inWhitespace = isWS
            current.append(ch)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Returns indices in `from` that differ from `to`
    private func wordDiffIndices(from: [String], to: [String]) -> Set<Int> {
        var changed = Set<Int>()
        let toSet = Set(to)
        for (i, word) in from.enumerated() {
            if !toSet.contains(word) {
                changed.insert(i)
            }
        }
        // If everything is different, don't highlight (avoids full-line highlight)
        if changed.count == from.count && from.count > 2 { return [] }
        return changed
    }

    private var fileExtension: String {
        (filePath as NSString).pathExtension.lowercased()
    }

    /// Basic syntax coloring for common tokens
    @ViewBuilder
    private func syntaxColoredText(_ text: String, fileExtension: String) -> some View {
        if Self.syntaxKeywords(for: fileExtension).isEmpty {
            Text(text)
        } else {
            Text(buildSyntaxAttributedString(text, ext: fileExtension))
        }
    }

    private func buildSyntaxAttributedString(_ text: String, ext: String) -> AttributedString {
        var result = AttributedString(text)
        let keywords = Self.syntaxKeywords(for: ext)

        // Highlight keywords
        for keyword in keywords {
            var searchRange = result.startIndex..<result.endIndex
            while let range = result[searchRange].range(of: keyword, options: []) {
                let absRange = range
                // Check word boundaries
                let beforeOK = absRange.lowerBound == result.startIndex || !result.characters[result.characters.index(before: absRange.lowerBound)].isLetter
                let afterOK = absRange.upperBound == result.endIndex || !result.characters[absRange.upperBound].isLetter
                if beforeOK && afterOK {
                    result[absRange].foregroundColor = .init(red: 0.7, green: 0.4, blue: 0.9)  // purple for keywords
                }
                searchRange = absRange.upperBound..<result.endIndex
            }
        }

        // Highlight strings (simple: anything between quotes)
        var inString = false
        var stringStart = result.startIndex
        for idx in result.characters.indices {
            let ch = result.characters[idx]
            if ch == "\"" {
                if inString {
                    let nextIdx = result.characters.index(after: idx)
                    result[stringStart..<nextIdx].foregroundColor = .init(red: 0.8, green: 0.5, blue: 0.2) // orange for strings
                    inString = false
                } else {
                    stringStart = idx
                    inString = true
                }
            }
        }

        // Highlight comments (//)
        if let commentRange = result.range(of: "//") {
            result[commentRange.lowerBound..<result.endIndex].foregroundColor = .init(white: 0.5) // gray for comments
        }

        return result
    }

    private static func syntaxKeywords(for ext: String) -> [String] {
        switch ext {
        case "swift":
            return ["func", "var", "let", "if", "else", "guard", "return", "import", "struct", "class", "enum", "case", "self", "private", "public", "static", "override", "init", "for", "while", "in", "try", "catch", "throw", "async", "await", "some", "nil", "true", "false"]
        case "py":
            return ["def", "class", "if", "else", "elif", "return", "import", "from", "for", "while", "in", "try", "except", "with", "as", "self", "None", "True", "False", "async", "await", "raise", "yield"]
        case "js", "ts", "jsx", "tsx":
            return ["function", "const", "let", "var", "if", "else", "return", "import", "export", "class", "new", "this", "for", "while", "try", "catch", "throw", "async", "await", "null", "undefined", "true", "false", "from"]
        case "rs":
            return ["fn", "let", "mut", "if", "else", "return", "use", "struct", "enum", "impl", "pub", "self", "for", "while", "in", "match", "Some", "None", "Ok", "Err", "async", "await", "true", "false"]
        case "go":
            return ["func", "var", "if", "else", "return", "import", "struct", "type", "for", "range", "package", "defer", "go", "chan", "select", "nil", "true", "false"]
        default:
            return []
        }
    }

    // MARK: - Side-by-Side View

    private var sideBySideView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sideBySidePairs.enumerated()), id: \.offset) { _, pair in
                    HStack(spacing: 0) {
                        // Left (old)
                        HStack(spacing: 0) {
                            Text(pair.oldNum.map { "\($0)" } ?? "")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(TextGrade.ghost)
                                .frame(width: 28, alignment: .trailing)

                            Text(pair.oldText ?? "")
                                .font(AppFont.codeSmall)
                                .foregroundStyle(pair.oldType == .removed ? Semantic.error : TextGrade.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, AppSpace.xs)
                        }
                        .padding(.vertical, 1.5)
                        .padding(.horizontal, AppSpace.sm)
                        .background(pair.oldType == .removed ? Semantic.error.opacity(0.10) : Color.clear)

                        Rectangle().fill(SurfaceGrade.divider).frame(width: 1)

                        // Right (new)
                        HStack(spacing: 0) {
                            Text(pair.newNum.map { "\($0)" } ?? "")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(TextGrade.ghost)
                                .frame(width: 28, alignment: .trailing)

                            Text(pair.newText ?? "")
                                .font(AppFont.codeSmall)
                                .foregroundStyle(pair.newType == .added ? Semantic.success : TextGrade.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, AppSpace.xs)
                        }
                        .padding(.vertical, 1.5)
                        .padding(.horizontal, AppSpace.sm)
                        .background(pair.newType == .added ? Semantic.success.opacity(0.10) : Color.clear)
                    }
                }
            }
        }
        .frame(maxHeight: isExpanded ? 600 : 240)
    }

    // MARK: - Colors

    private func lineColor(_ type: DiffLineType) -> Color {
        switch type {
        case .added: return Semantic.success
        case .removed: return Semantic.error
        case .context: return TextGrade.ghost
        }
    }

    private func lineTextColor(_ type: DiffLineType) -> Color {
        switch type {
        case .added: return Semantic.success
        case .removed: return Semantic.error
        case .context: return TextGrade.secondary
        }
    }

    private func lineBackground(_ type: DiffLineType) -> Color {
        switch type {
        case .added: return Semantic.success.opacity(0.10)
        case .removed: return Semantic.error.opacity(0.10)
        case .context: return Color.clear
        }
    }

    // MARK: - Stats

    private var diffStats: (added: Int, removed: Int) {
        var a = 0, r = 0
        for line in diffLines {
            if line.type == .added { a += 1 }
            if line.type == .removed { r += 1 }
        }
        return (a, r)
    }

    // MARK: - Diff Computation

    private func computeNumberedDiff() -> [NumberedDiffLine] {
        let o = oldContent.components(separatedBy: "\n")
        let n = newContent.components(separatedBy: "\n")
        var result: [NumberedDiffLine] = []
        var oldIdx = 1, newIdx = 1

        for i in 0..<min(o.count, n.count) {
            if o[i] == n[i] {
                result.append(NumberedDiffLine(type: .context, content: o[i], oldNum: oldIdx, newNum: newIdx))
                oldIdx += 1; newIdx += 1
            } else {
                result.append(NumberedDiffLine(type: .removed, content: o[i], oldNum: oldIdx, newNum: nil))
                oldIdx += 1
                result.append(NumberedDiffLine(type: .added, content: n[i], oldNum: nil, newNum: newIdx))
                newIdx += 1
            }
        }
        for i in min(o.count, n.count)..<o.count {
            result.append(NumberedDiffLine(type: .removed, content: o[i], oldNum: oldIdx, newNum: nil))
            oldIdx += 1
        }
        for i in min(o.count, n.count)..<n.count {
            result.append(NumberedDiffLine(type: .added, content: n[i], oldNum: nil, newNum: newIdx))
            newIdx += 1
        }
        return result
    }

    private var sideBySidePairs: [SideBySideLine] {
        var pairs: [SideBySideLine] = []
        var i = 0
        let lines = diffLines
        while i < lines.count {
            let line = lines[i]
            if line.type == .context {
                pairs.append(SideBySideLine(
                    oldNum: line.oldNum, oldText: line.content, oldType: .context,
                    newNum: line.newNum, newText: line.content, newType: .context
                ))
                i += 1
            } else if line.type == .removed {
                // Check if next line is added (paired change)
                if i + 1 < lines.count && lines[i + 1].type == .added {
                    let next = lines[i + 1]
                    pairs.append(SideBySideLine(
                        oldNum: line.oldNum, oldText: line.content, oldType: .removed,
                        newNum: next.newNum, newText: next.content, newType: .added
                    ))
                    i += 2
                } else {
                    pairs.append(SideBySideLine(
                        oldNum: line.oldNum, oldText: line.content, oldType: .removed,
                        newNum: nil, newText: nil, newType: .context
                    ))
                    i += 1
                }
            } else {
                pairs.append(SideBySideLine(
                    oldNum: nil, oldText: nil, oldType: .context,
                    newNum: line.newNum, newText: line.content, newType: .added
                ))
                i += 1
            }
        }
        return pairs
    }
}

// MARK: - Diff Data Types

struct NumberedDiffLine {
    let type: DiffLineType
    let content: String
    let oldNum: Int?
    let newNum: Int?
}

struct SideBySideLine {
    let oldNum: Int?
    let oldText: String?
    let oldType: DiffLineType
    let newNum: Int?
    let newText: String?
    let newType: DiffLineType
}

// MARK: - Orchestration Debug Card

struct OrchestrationDebugCard: View {
    let text: String
    let label: String
    @State private var isExpanded = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Brand.purple.opacity(0.5))
                Image(systemName: "gearshape.2")
                    .font(.system(size: 9))
                    .foregroundStyle(Brand.purple.opacity(0.5))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Brand.purple.opacity(0.6))
                if !isExpanded {
                    Text(String(text.prefix(60)).replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 10))
                        .foregroundStyle(TextGrade.muted.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, AppSpace.sm)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)

        if isExpanded {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(TextGrade.muted.opacity(0.7))
                .textSelection(.enabled)
                .padding(.horizontal, AppSpace.md)
                .padding(.vertical, AppSpace.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                        .fill(Brand.purple.opacity(0.03))
                )
                .padding(.horizontal, AppSpace.sm)
        }
    }
}
