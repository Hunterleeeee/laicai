import AppKit
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
                } else if let imagePath {
                    GeneratedImagePreviewCard(path: imagePath, caption: displayText)
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

    private var imagePath: String? {
        guard step.toolName == "image.generate", !step.isFailure else { return nil }
        if let path = step.toolParams?["imagePath"], FileManager.default.fileExists(atPath: path) {
            return path
        }
        return Self.firstImagePath(in: step.text)
    }

    private static func firstImagePath(in text: String) -> String? {
        let pattern = #"(/[^\n\r\t]+?\.(?:png|jpg|jpeg|webp|heic))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let raw = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "。.,，)）]】\"'"))
        return FileManager.default.fileExists(atPath: raw) ? raw : nil
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

struct GeneratedImagePreviewCard: View {
    @EnvironmentObject private var store: AppStore
    let path: String
    let caption: String

    private var url: URL {
        URL(fileURLWithPath: path)
    }

    private var filename: String {
        url.lastPathComponent
    }

    private var fileSizeLabel: String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else { return "" }
        let value = size.doubleValue
        if value >= 1_048_576 { return String(format: "%.1f MB", value / 1_048_576) }
        if value >= 1024 { return String(format: "%.0f KB", value / 1024) }
        return "\(Int(value)) B"
    }

    private var imageDimensionsLabel: String {
        guard let image = NSImage(contentsOfFile: path) else { return "" }
        return "\(Int(image.size.width)) x \(Int(image.size.height))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            HStack(spacing: AppSpace.sm) {
                Image(systemName: "photo.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Semantic.success)

                VStack(alignment: .leading, spacing: 2) {
                    Text("图片已生成")
                        .font(AppFont.captionMedium)
                        .foregroundStyle(TextGrade.primary)
                    HStack(spacing: AppSpace.sm) {
                        Text(filename)
                            .font(AppFont.codeSmall)
                            .foregroundStyle(TextGrade.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !imageDimensionsLabel.isEmpty {
                            Text(imageDimensionsLabel)
                        }
                        if !fileSizeLabel.isEmpty {
                            Text(fileSizeLabel)
                        }
                    }
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.ghost)
                }

                Spacer(minLength: AppSpace.sm)

                imageAction(icon: "arrow.clockwise", label: "重新生成") {
                    store.retryLastMessage()
                }
                imageAction(icon: "doc.on.doc", label: "复制路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                    ToastCenter.shared.success("已复制图片路径")
                }
            }

            if let image = NSImage(contentsOfFile: path) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 640, maxHeight: 420)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                                .strokeBorder(SurfaceGrade.border.opacity(0.25), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .help("打开图片")
            } else {
                VStack(alignment: .leading, spacing: AppSpace.xs) {
                    Text("图片文件暂时无法预览")
                        .font(AppFont.captionMedium)
                        .foregroundStyle(Semantic.warning)
                    Text(path)
                        .font(AppFont.codeSmall)
                        .foregroundStyle(TextGrade.ghost)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .padding(AppSpace.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).fill(SurfaceGrade.sunken.opacity(0.42)))
            }

            HStack(spacing: AppSpace.sm) {
                imageAction(icon: "arrow.up.right.square", label: "打开") {
                    NSWorkspace.shared.open(url)
                }
                imageAction(icon: "folder", label: "Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }

                Spacer(minLength: AppSpace.sm)

                Text(path)
                    .font(AppFont.codeSmall)
                    .foregroundStyle(TextGrade.ghost)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Text(caption)
                .font(AppFont.tiny)
                .foregroundStyle(TextGrade.ghost)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(AppSpace.md)
        .frame(maxWidth: 680, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .fill(SurfaceGrade.card.opacity(0.68))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(Semantic.success.opacity(0.22), lineWidth: 0.8)
        )
    }

    private func imageAction(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(AppFont.tiny)
            }
            .foregroundStyle(TextGrade.secondary)
            .padding(.horizontal, AppSpace.sm)
            .padding(.vertical, 5)
            .background(Capsule().fill(SurfaceGrade.elevated.opacity(0.72)))
            .overlay(Capsule().strokeBorder(SurfaceGrade.border.opacity(0.28), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(label)
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

            VStack(alignment: .leading, spacing: AppSpace.sm) {
                HStack(spacing: AppSpace.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failureTitle)
                            .font(AppFont.captionMedium)
                            .foregroundStyle(Semantic.error)
                        Text(failureHint)
                            .font(AppFont.tiny)
                            .foregroundStyle(TextGrade.ghost)
                            .lineLimit(2)
                    }
                    Spacer(minLength: AppSpace.sm)
                    Text(failureKindLabel)
                        .font(AppFont.tiny)
                        .foregroundStyle(Semantic.error)
                        .padding(.horizontal, AppSpace.sm)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Semantic.errorMuted.opacity(0.55)))
                }

                Text(step.text)
                    .font(AppFont.body)
                    .foregroundStyle(TextGrade.secondary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                HStack(spacing: AppSpace.sm) {
                    failureAction(icon: "arrow.clockwise", label: "重试", isPrimary: true) {
                        store.retryLastMessage()
                    }

                    if shouldOpenSettings {
                        failureAction(icon: "gearshape", label: settingsActionTitle) {
                            NotificationCenter.default.post(name: .init("laicaiOpenSettings"), object: nil)
                        }
                    }

                    failureAction(icon: "doc.on.doc", label: "复制诊断") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(step.text, forType: .string)
                        ToastCenter.shared.success("已复制诊断")
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
        if isImageFailure { return "图片生成失败" }
        if isNetworkFailure { return "网络连接中断" }
        if step.text.contains("超时") { return "模型请求超时" }
        if isAuthFailure { return "模型鉴权失败" }
        if isWorkspaceFailure { return "工作区配置异常" }
        return "失败，需处理"
    }

    private var failureHint: String {
        if isImageFailure { return "优先检查图片模型、网关连接和返回内容。" }
        if isNetworkFailure { return "请求已发出但连接中途断开，可以直接重试或检查代理/网关。" }
        if isAuthFailure { return "API Key、模型名或兼容接口配置可能不正确。" }
        if isWorkspaceFailure { return "工作区目录为空、过宽或无权限。" }
        if step.text.contains("超时") { return "任务可能仍在服务端排队，可以重试或换更快模型。" }
        return "已保留诊断内容，可复制后继续排查。"
    }

    private var failureKindLabel: String {
        if isImageFailure { return "图片" }
        if isNetworkFailure { return "网络" }
        if isAuthFailure { return "鉴权" }
        if isWorkspaceFailure { return "工作区" }
        if step.text.contains("超时") { return "超时" }
        return "错误"
    }

    private var shouldOpenSettings: Bool {
        isAuthFailure || isImageFailure || isWorkspaceFailure || step.text.contains("超时")
    }

    private var settingsActionTitle: String {
        if isWorkspaceFailure { return "检查工作区" }
        if step.text.contains("超时") { return "调整模型" }
        return "检查配置"
    }

    private var isImageFailure: Bool {
        step.text.contains("图片") || step.text.localizedCaseInsensitiveContains("image.generate") || step.text.localizedCaseInsensitiveContains("gpt-image")
    }

    private var isNetworkFailure: Bool {
        step.text.contains("网络") || step.text.contains("连接") || step.text.localizedCaseInsensitiveContains("networkConnectionLost") || step.text.localizedCaseInsensitiveContains("timed out")
    }

    private var isAuthFailure: Bool {
        step.text.contains("鉴权") || step.text.contains("401") || step.text.localizedCaseInsensitiveContains("API key") || step.text.localizedCaseInsensitiveContains("unauthorized")
    }

    private var isWorkspaceFailure: Bool {
        step.text.contains("工作区") || step.text.localizedCaseInsensitiveContains("workspace")
    }

    private func failureAction(icon: String, label: String, isPrimary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(AppFont.captionMedium)
                .foregroundStyle(isPrimary ? Color.white : TextGrade.secondary)
                .padding(.horizontal, AppSpace.md)
                .padding(.vertical, AppSpace.sm)
                .background(Capsule().fill(isPrimary ? Brand.primary : SurfaceGrade.elevated.opacity(0.62)))
                .overlay(Capsule().strokeBorder(isPrimary ? Color.clear : SurfaceGrade.border.opacity(0.28), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
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
