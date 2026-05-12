import SwiftUI
import LaicaiNativeDomain
import LaicaiNativeFoundation

// MARK: - Welcome View

struct WelcomeView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showingSettings: Bool

    private let samplePrompts = [
        (icon: "magnifyingglass", text: "帮我审查最近的 git 变更", sub: "自动扫描 diff 并给出改进建议"),
        (icon: "hammer", text: "重构这个项目的错误处理逻辑", sub: "分析代码结构，生成重构方案"),
        (icon: "doc.text", text: "给核心模块生成文档", sub: "提取类型签名，输出 Markdown 文档"),
        (icon: "ant", text: "排查并修复最近出现的 bug", sub: "搜索日志和代码，定位根因"),
    ]

    @ObservedObject private var projectManager = ProjectManager.shared
    @State private var orbRotation: Double = 0

    // Composer overlay height (input area at bottom)
    private let composerHeight: CGFloat = 120

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let isCompact = h < 760
            let isNarrow = w < 560
            let gap: CGFloat = isCompact ? 14 : 24
            let contentWidth = isNarrow ? w - 32 : min(600, w * 0.75)

            ZStack {
                ambientBackground

                ScrollView(showsIndicators: false) {
                    VStack(spacing: gap) {
                        heroSection(compact: isCompact)

                        if store.state.activeConnector == nil {
                            connectPrompt
                        } else {
                            samplePromptsGrid(narrow: isNarrow)
                        }

                        capabilityCards(narrow: isNarrow)

                        keyboardHints
                    }
                    .frame(maxWidth: contentWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, isNarrow ? AppSpace.md : AppSpace.xl)
                    .padding(.top, isCompact ? 16 : 32)
                    .padding(.bottom, composerHeight)
                }
            }
        }
    }

    // MARK: - Ambient Background

    private var ambientBackground: some View {
        ZStack {
            // Orb 1 — blue
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Brand.primary.opacity(0.20), Brand.primary.opacity(0.0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 200
                    )
                )
                .frame(width: 400, height: 400)
                .offset(x: -120, y: -80)
                .blur(radius: 80)
                .rotationEffect(.degrees(orbRotation))

            // Orb 2 — purple
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Brand.purple.opacity(0.15), Brand.purple.opacity(0.0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 180
                    )
                )
                .frame(width: 350, height: 350)
                .offset(x: 150, y: 60)
                .blur(radius: 70)
                .rotationEffect(.degrees(-orbRotation * 0.7))

            // Orb 3 — teal
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Brand.teal.opacity(0.10), Brand.teal.opacity(0.0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 150
                    )
                )
                .frame(width: 300, height: 300)
                .offset(x: -60, y: 180)
                .blur(radius: 60)
                .rotationEffect(.degrees(orbRotation * 0.5))
        }
        .onAppear {
            withAnimation(.linear(duration: 60).repeatForever(autoreverses: false)) {
                orbRotation = 360
            }
        }
    }

    // MARK: - Hero

    private var heroTitle: String {
        if let projectID = store.state.selectedThread?.projectID,
           let project = projectManager.projects.first(where: { $0.id == projectID }) {
            return "要在 \(project.name) 中构建什么？"
        }
        return "有什么我能帮你的？"
    }

    @State private var heroGlowPulse = false

    private func heroSection(compact: Bool) -> some View {
        let logoSize: CGFloat = compact ? 40 : 52
        let ringSize: CGFloat = compact ? 58 : 74
        let glowSize: CGFloat = compact ? 68 : 86
        let titleSize: CGFloat = compact ? 20 : 24

        return VStack(spacing: compact ? 12 : 18) {
            ZStack {
                RoundedRectangle(cornerRadius: ringSize * 0.26, style: .continuous)
                    .strokeBorder(
                        AngularGradient(
                            colors: [Brand.primary, Brand.purple, Brand.teal, Brand.primary],
                            center: .center
                        ),
                        lineWidth: 2
                    )
                    .frame(width: ringSize, height: ringSize)
                    .rotationEffect(.degrees(orbRotation * 2))
                    .opacity(0.5)

                RoundedRectangle(cornerRadius: glowSize * 0.24, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [
                                Brand.primary.opacity(0.22),
                                Brand.purple.opacity(0.10),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: logoSize * 0.2,
                            endRadius: glowSize * 0.5
                        )
                    )
                    .frame(width: glowSize, height: glowSize)
                    .scaleEffect(heroGlowPulse ? 1.06 : 0.94)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                            heroGlowPulse = true
                        }
                    }

                BrandLogo(size: logoSize)
                    .shadow(color: Brand.primary.opacity(0.5), radius: 20, y: 0)
            }
            .frame(height: glowSize + 8)

            VStack(spacing: compact ? 6 : 10) {
                Text(heroTitle)
                    .font(.system(size: titleSize, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [TextGrade.primary, TextGrade.secondary],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                Text("描述你的目标，来财自动决定搜索、分析还是直接动手")
                    .font(.system(size: compact ? 11 : 13, weight: .regular))
                    .foregroundStyle(TextGrade.muted)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Connect Prompt

    private var connectPrompt: some View {
        VStack(spacing: AppSpace.lg) {
            Button {
                showingSettings = true
            } label: {
                HStack(spacing: AppSpace.sm) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 15))
                    Text("配置 AI 模型")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, AppSpace.xl)
                .padding(.vertical, AppSpace.md)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Brand.gradientStart, Brand.gradientEnd],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
                .shadow(color: Brand.primary.opacity(0.30), radius: 12, y: 4)
            }
            .buttonStyle(.plain)

            Text("连接 OpenAI、Ollama 或兼容 API 后即可开始")
                .font(AppFont.caption)
                .foregroundStyle(TextGrade.ghost)
        }
    }

    // MARK: - Sample Prompts

    private func samplePromptsGrid(narrow: Bool) -> some View {
        let columns = narrow
            ? [GridItem(.flexible())]
            : [GridItem(.flexible()), GridItem(.flexible())]

        return LazyVGrid(columns: columns, spacing: AppSpace.sm) {
            ForEach(Array(samplePrompts.enumerated()), id: \.offset) { _, prompt in
                SamplePromptRow(icon: prompt.icon, text: prompt.text, subtitle: prompt.sub) {
                    store.updateDraft(prompt.text)
                }
            }
        }
    }

    // MARK: - Capabilities

    @ViewBuilder
    private func capabilityCards(narrow: Bool) -> some View {
        let cards = Group {
            CapabilityCard(
                icon: "bolt.fill",
                iconColor: Brand.primary,
                title: "一个入口",
                description: "说目标，系统自己决定该怎么做"
            )

            CapabilityCard(
                icon: "text.bubble.fill",
                iconColor: Brand.purple,
                title: "连续会话",
                description: "讨论、工具、审查在同一条时间线"
            )

            CapabilityCard(
                icon: "arrow.triangle.branch",
                iconColor: Semantic.success,
                title: "工作流",
                description: "批量审查、重构、文档一键启动"
            )
        }

        if narrow {
            VStack(spacing: AppSpace.sm) { cards }
        } else {
            HStack(spacing: AppSpace.md) { cards }
        }
    }

    // MARK: - Keyboard Hints

    private var keyboardHints: some View {
        HStack(spacing: AppSpace.xl) {
            KeyHint(keys: "↵", desc: "发送")
            KeyHint(keys: "⇧↵", desc: "换行")
            KeyHint(keys: "⌘N", desc: "新会话")
            KeyHint(keys: "⌘K", desc: "命令面板")
        }
    }
}

// MARK: - Sample Prompt Row

struct SamplePromptRow: View {
    let icon: String
    let text: String
    var subtitle: String = ""
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpace.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                        .fill(isHovered ? Brand.primary.opacity(0.15) : SurfaceGrade.card)
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isHovered ? Brand.primary : TextGrade.muted)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isHovered ? TextGrade.primary : TextGrade.secondary)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(TextGrade.ghost)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isHovered ? Brand.primary : Color.clear)
                    .offset(x: isHovered ? 0 : -4)
            }
            .padding(.horizontal, AppSpace.lg)
            .padding(.vertical, AppSpace.md)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .strokeBorder(
                        isHovered
                            ? LinearGradient(colors: [Brand.primary.opacity(0.5), Brand.purple.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            : LinearGradient(colors: [SurfaceGrade.border.opacity(0.3), SurfaceGrade.border.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: isHovered ? 1 : 0.5
                    )
            )
            .shadow(color: isHovered ? Brand.primary.opacity(0.15) : Color.clear, radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(AppAnimation.standard) { isHovered = h }
        }
    }
}

// MARK: - Capability Card

struct CapabilityCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(isHovered ? 0.15 : 0.08))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: AppSpace.xs) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TextGrade.primary)

                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(TextGrade.muted)
                    .lineLimit(2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .strokeBorder(
                    isHovered ? iconColor.opacity(0.3) : SurfaceGrade.border.opacity(0.2),
                    lineWidth: isHovered ? 1 : 0.5
                )
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .shadow(color: isHovered ? iconColor.opacity(0.12) : Color.clear, radius: 12, y: 4)
        .onHover { h in
            withAnimation(AppAnimation.standard) { isHovered = h }
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
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(SurfaceGrade.card.opacity(0.6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(SurfaceGrade.border.opacity(0.4), lineWidth: 0.5)
                        )
                )
            Text(desc)
                .font(AppFont.tiny)
                .foregroundStyle(TextGrade.ghost)
        }
    }
}
