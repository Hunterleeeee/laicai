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
            icon: "magnifyingglass",
            tint: Brand.primary,
            text: "审查最近的 git 变更",
            sub: "扫描 diff 并给出改进建议"
        ),
        SamplePrompt(
            icon: "hammer",
            tint: Semantic.warning,
            text: "重构错误处理逻辑",
            sub: "分析代码结构，提出重构方案"
        ),
        SamplePrompt(
            icon: "doc.text",
            tint: Brand.teal,
            text: "给核心模块写文档",
            sub: "提取类型签名，输出 Markdown"
        ),
        SamplePrompt(
            icon: "photo",
            tint: Brand.purple,
            text: "生成一张产品介绍图",
            sub: "海报、封面或介绍图"
        )
    ]

    private let composerHeight: CGFloat = 132

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let isCompact = h < 720
            let isNarrow = w < 620
            let contentWidth: CGFloat = isNarrow ? w - 32 : min(760, w * 0.82)
            let topPad: CGFloat = isCompact ? 30 : max(44, h * 0.08)

            ZStack {
                ambientBackground

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: isCompact ? 22 : 30) {
                        heroSection(compact: isCompact)

                        if store.state.activeConnector == nil {
                            connectPrompt
                        } else {
                            VStack(alignment: .leading, spacing: AppSpace.lg) {
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
            ? "连接一个模型后，就可以启动 Agent、读取项目和运行工具。"
            : "从常用起点开始，或者直接在下方输入一个明确目标。"
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
                icon: "plus.message",
                title: "启动新 Agent",
                subtitle: "给它一个目标",
                tint: Brand.primary
            ) {
                store.newTask()
            }

            if let lastTask = recentTask {
                PrimaryActionTile(
                    icon: "arrow.turn.down.right",
                    title: "继续 · \(TextHelper.compactTitle(lastTask.title))",
                    subtitle: "接着上次的处理",
                    tint: Brand.teal
                ) {
                    store.selectAgent(id: lastTask.id)
                }
            } else {
                PrimaryActionTile(
                    icon: "folder.badge.gearshape",
                    title: projectManager.activeProject?.name ?? "审视当前项目",
                    subtitle: "看看还有哪些待办",
                    tint: Brand.purple
                ) {
                    store.updateDraft("全面看一下当前项目还有哪些问题，并直接修复")
                }
            }
        }
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
            KeyHint(keys: "⌘N", desc: "新 Agent")
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
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpace.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                        .fill(tint.opacity(isHovered ? 0.18 : 0.12))
                        .frame(width: 34, height: 34)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TextGrade.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(TextGrade.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isHovered ? tint : TextGrade.ghost.opacity(0.6))
                    .offset(x: isHovered ? 2 : 0)
            }
            .padding(.horizontal, AppSpace.md)
            .padding(.vertical, AppSpace.md)
            .background(SurfaceGrade.card.opacity(0.86))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .strokeBorder(
                        isHovered ? tint.opacity(0.35) : SurfaceGrade.hairline,
                        lineWidth: isHovered ? 1 : 0.7
                    )
            )
            .shadow(color: Color.black.opacity(0.035), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(AppAnimation.quick) { isHovered = hovering }
        }
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
        .onHover { h in
            withAnimation(AppAnimation.quick) { isHovered = h }
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
