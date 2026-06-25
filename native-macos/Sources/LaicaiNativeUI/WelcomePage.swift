import SwiftUI
import LaicaiNativeDomain
import LaicaiNativeFoundation

// MARK: - Welcome View

struct WelcomeView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showingSettings: Bool

    @ObservedObject private var projectManager = ProjectManager.shared

    private let samplePrompts: [SamplePrompt] = [
        SamplePrompt(
            icon: "stethoscope",
            tint: Brand.primary,
            text: "全面检查当前项目",
            sub: "找出最影响体验的问题"
        ),
        SamplePrompt(
            icon: "wrench.adjustable",
            tint: Semantic.warning,
            text: "直接修一个问题",
            sub: "定位、修改并验证"
        ),
        SamplePrompt(
            icon: "doc.text",
            tint: Brand.teal,
            text: "整理本次改动说明",
            sub: "输出可读的交付记录"
        ),
        SamplePrompt(
            icon: "book.closed",
            tint: Brand.purple,
            text: "沉淀到 Wiki",
            sub: "把结论写入知识库"
        )
    ]

    private let composerHeight: CGFloat = 132

    var body: some View {
        GeometryReader { geometry in
            let viewportWidth = geometry.size.width
            let viewportHeight = geometry.size.height
            let isCompact = viewportHeight < 720
            let isNarrow = viewportWidth < 620
            let contentWidth: CGFloat = isNarrow ? viewportWidth - 32 : min(760, viewportWidth * 0.82)
            let topPad: CGFloat = isCompact ? 30 : max(44, viewportHeight * 0.08)

            ZStack {
                ambientBackground

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: isCompact ? 22 : 30) {
                        heroSection(compact: isCompact)

                        if store.state.activeConnector == nil {
                            connectPrompt
                        } else {
                            VStack(alignment: .leading, spacing: AppSpace.lg) {
                                contextStrip(narrow: isNarrow)
                                quickActionRow(narrow: isNarrow)
                                Divider().background(SurfaceGrade.hairline)
                                samplePromptsGrid(narrow: isNarrow)
                            }
                        }

                        keyboardHints
                    }
                    .frame(maxWidth: contentWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, isNarrow ? AppSpace.md : AppSpace.xl)
                    .padding(.top, topPad)
                    .padding(.bottom, composerHeight + AppSpace.lg)
                }
            }
        }
    }

    // MARK: - Ambient Background

    private var ambientBackground: some View {
        ZStack {
            SurfaceGrade.base
            Brand.subtleGradient.ignoresSafeArea()
            VStack {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Brand.primary.opacity(0.06), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 180)
                Spacer()
            }
        }
    }

    // MARK: - Hero

    private var heroTitle: String {
        if let projectID = store.state.selectedThread?.projectID,
           let project = projectManager.projects.first(where: { $0.id == projectID }) {
            return "在 \(project.name) 中要做什么？"
        }
        return "今天想做什么？"
    }

    private var heroSubtitle: String {
        store.state.activeConnector == nil
            ? "先连接一个模型，然后就可以读取项目、运行工具和完成任务。"
            : "先选一个入口，或者直接在下方输入目标。"
    }

    private func heroSection(compact: Bool) -> some View {
        let logoSize: CGFloat = compact ? 38 : 44

        return HStack(alignment: .center, spacing: AppSpace.lg) {
            BrandLogo(size: logoSize)
                .shadow(color: Brand.jade.opacity(0.18), radius: 12, y: 4)

            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                Text(heroTitle)
                    .font(.system(size: compact ? 22 : 26, weight: .semibold))
                    .foregroundStyle(TextGrade.primary)
                    .lineLimit(2)

                Text(heroSubtitle)
                    .font(.system(size: compact ? 12 : 13))
                    .foregroundStyle(TextGrade.muted)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Connect Prompt (when no connector is set)

    private var connectPrompt: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            Button {
                showingSettings = true
            } label: {
                HStack(spacing: AppSpace.sm) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text("连接 AI 模型")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, AppSpace.xl)
                .padding(.vertical, AppSpace.md)
                .background(Capsule().fill(Brand.jade))
                .shadow(color: Brand.jade.opacity(0.18), radius: 12, y: 4)
            }
            .buttonStyle(.plain)

            Text("OpenAI · Anthropic · DeepSeek · Ollama 任意一种均可")
                .font(AppFont.caption)
                .foregroundStyle(TextGrade.ghost)
        }
        .padding(.vertical, AppSpace.sm)
    }

    // MARK: - Primary Actions

    private func quickActionRow(narrow: Bool) -> some View {
        let columns = narrow
            ? [GridItem(.flexible())]
            : [GridItem(.flexible()), GridItem(.flexible())]

        return LazyVGrid(columns: columns, spacing: AppSpace.sm) {
            PrimaryActionTile(
                icon: "hammer",
                title: "执行一个目标",
                subtitle: "读项目、跑工具、做验证",
                tint: Brand.primary,
                prominence: .primary
            ) {
                startTask()
            }

            PrimaryActionTile(
                icon: "bubble.left.and.bubble.right",
                title: "问一个问题",
                subtitle: "不动文件，先聊清楚",
                tint: Brand.teal
            ) {
                store.newThread()
            }

            if let lastTask = recentTask {
                PrimaryActionTile(
                    icon: "arrow.turn.down.right",
                    title: "继续 · \(TextHelper.compactTitle(lastTask.title))",
                    subtitle: "接着上次上下文",
                    tint: Brand.teal
                ) {
                    store.selectThread(id: lastTask.id)
                }
            } else {
                PrimaryActionTile(
                    icon: "folder.badge.gearshape",
                    title: projectManager.activeProject?.name ?? "检查当前项目",
                    subtitle: "先找最值得修的点",
                    tint: Brand.purple
                ) {
                    startTask(draft: "全面看一下当前项目还有哪些问题，按影响排序，并直接修复最重要的一项")
                }
            }
        }
    }

    private func contextStrip(narrow: Bool) -> some View {
        let projectLabel = projectManager.activeProject?.name ?? "未选择项目"
        let modelLabel = store.state.activeConnector?.modelName.isEmpty == false
            ? (store.state.activeConnector?.modelName ?? "已连接模型")
            : (store.state.activeConnector?.name ?? "已连接模型")

        return HStack(spacing: AppSpace.sm) {
            ContextPill(icon: "cpu", text: modelLabel, tint: Brand.teal)
            ContextPill(
                icon: "folder",
                text: projectLabel,
                tint: projectManager.activeProject == nil ? TextGrade.muted : Brand.primary
            )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, narrow ? 0 : AppSpace.xs)
    }

    private func startTask(draft: String = "请直接处理这个目标：") {
        if let projectID = projectManager.activeProjectID {
            store.newThreadInProject(projectID)
        } else {
            store.newThread()
        }
        store.updateDraft(draft)
    }

    private var recentTask: Thread? {
        store.state.continuableAgents
            .compactMap { agent in store.state.threads.first { $0.id == agent.id } }
            .first
    }

    private func samplePromptsGrid(narrow: Bool) -> some View {
        let columns = narrow
            ? [GridItem(.flexible())]
            : [GridItem(.flexible()), GridItem(.flexible())]

        return VStack(alignment: .leading, spacing: AppSpace.sm) {
            Text("常用起点")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TextGrade.ghost)
                .textCase(.uppercase)
                .padding(.leading, 2)

            LazyVGrid(columns: columns, spacing: AppSpace.sm) {
                ForEach(samplePrompts) { prompt in
                    SamplePromptCard(prompt: prompt) {
                        store.updateDraft(prompt.text)
                    }
                }
            }
        }
    }

    // MARK: - Keyboard Hints

    private var keyboardHints: some View {
        HStack(spacing: AppSpace.lg) {
            KeyHint(keys: "↵", desc: "发送")
            KeyHint(keys: "⇧↵", desc: "换行")
            KeyHint(keys: "⌘N", desc: "新任务")
            KeyHint(keys: "⌘⇧N", desc: "新会话")
            KeyHint(keys: "⌘K", desc: "命令面板")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, AppSpace.sm)
    }
}

// MARK: - Sample Prompt Model

struct SamplePrompt: Identifiable {
    let id = UUID()
    let icon: String
    let tint: Color
    let text: String
    let sub: String
}

// MARK: - Primary Action Tile

struct PrimaryActionTile: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color
    var prominence: PrimaryActionProminence = .normal
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpace.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                        .fill(iconBackground)
                        .frame(width: 34, height: 34)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(iconForeground)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(subtitleColor)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(arrowColor)
                    .offset(x: isHovered ? 2 : 0)
            }
            .padding(.horizontal, AppSpace.md)
            .padding(.vertical, AppSpace.md)
            .background(tileBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .strokeBorder(
                        borderColor,
                        lineWidth: isHovered ? 1 : 0.7
                    )
            )
            .shadow(
                color: shadowColor,
                radius: prominence == .primary ? 10 : 3,
                y: prominence == .primary ? 4 : 1
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(AppAnimation.quick) { isHovered = hovering }
        }
    }

    private var tileBackground: Color {
        prominence == .primary ? (isHovered ? Brand.primaryHover : tint) : SurfaceGrade.card.opacity(0.86)
    }

    private var iconBackground: Color {
        prominence == .primary
            ? Color.white.opacity(isHovered ? 0.24 : 0.18)
            : tint.opacity(isHovered ? 0.18 : 0.12)
    }

    private var iconForeground: Color {
        prominence == .primary ? .white : tint
    }

    private var titleColor: Color {
        prominence == .primary ? .white : TextGrade.primary
    }

    private var subtitleColor: Color {
        prominence == .primary ? Color.white.opacity(0.82) : TextGrade.muted
    }

    private var arrowColor: Color {
        prominence == .primary
            ? Color.white.opacity(isHovered ? 1 : 0.78)
            : (isHovered ? tint : TextGrade.ghost.opacity(0.6))
    }

    private var borderColor: Color {
        prominence == .primary
            ? Color.white.opacity(isHovered ? 0.34 : 0.16)
            : (isHovered ? tint.opacity(0.35) : SurfaceGrade.hairline)
    }

    private var shadowColor: Color {
        prominence == .primary ? tint.opacity(0.22) : Color.black.opacity(0.035)
    }
}

enum PrimaryActionProminence {
    case normal
    case primary
}

// MARK: - Context Pill

private struct ContextPill: View {
    let icon: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: AppSpace.xs) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(AppFont.captionMedium)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, AppSpace.sm + 2)
        .frame(height: 24)
        .background(Capsule().fill(tint.opacity(0.10)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.18), lineWidth: 0.6))
    }
}

// MARK: - Sample Prompt Card

struct SamplePromptCard: View {
    let prompt: SamplePrompt
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: AppSpace.md) {
                Image(systemName: prompt.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isHovered ? prompt.tint : TextGrade.muted)
                    .frame(width: 24, height: 24)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(prompt.text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TextGrade.primary)
                        .lineLimit(1)
                    Text(prompt.sub)
                        .font(.system(size: 11))
                        .foregroundStyle(TextGrade.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppSpace.md)
            .padding(.vertical, AppSpace.sm + 2)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .fill(isHovered ? SurfaceGrade.card.opacity(0.92) : SurfaceGrade.elevated.opacity(0.46))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .strokeBorder(
                        isHovered ? prompt.tint.opacity(0.32) : SurfaceGrade.hairline,
                        lineWidth: isHovered ? 1 : 0.7
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            withAnimation(AppAnimation.quick) { isHovered = isHovering }
        }
    }
}

// MARK: - Key Hint

struct KeyHint: View {
    let keys: String
    let desc: String

    var body: some View {
        HStack(spacing: AppSpace.xs) {
            Text(keys)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(TextGrade.muted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(SurfaceGrade.elevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(SurfaceGrade.hairline, lineWidth: 0.5)
                )
            Text(desc)
                .font(.system(size: 10))
                .foregroundStyle(TextGrade.ghost)
        }
    }
}
