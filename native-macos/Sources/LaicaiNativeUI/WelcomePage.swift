import SwiftUI
import LaicaiNativeDomain
import LaicaiNativeFoundation

// MARK: - Welcome View

struct WelcomeView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showingSettings: Bool

    private let samplePrompts = [
        (icon: "magnifyingglass", text: "审查最近的 git 变更", sub: "读取 diff，指出风险和修法"),
        (icon: "book.closed", text: "整理这个文件夹到 Wiki", sub: "递归读取资料，生成知识页"),
        (icon: "waveform.path.ecg", text: "排查连接器或本地服务", sub: "检查 URL、模型、健康状态"),
        (icon: "wrench.and.screwdriver", text: "重构一处逻辑并验证构建", sub: "改代码、跑构建、汇报结果"),
    ]

    // Composer overlay height (input area at bottom)
    private let composerHeight: CGFloat = 128

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let isCompact = h < 760
            let isNarrow = w < 680
            let gap: CGFloat = isCompact ? 16 : 22
            let contentWidth = isNarrow ? w - 32 : min(760, w * 0.78)

            ZStack {
                welcomeBackground

                ScrollView(showsIndicators: false) {
                    VStack(spacing: gap) {
                        heroSection(compact: isCompact, narrow: isNarrow)

                        if store.state.activeConnector == nil {
                            connectPrompt
                        } else {
                            samplePromptsGrid(narrow: isNarrow)
                        }

                        welcomeHints(narrow: isNarrow)
                    }
                    .frame(maxWidth: contentWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, isNarrow ? AppSpace.md : AppSpace.xl)
                    .padding(.top, isCompact ? 18 : 34)
                    .padding(.bottom, composerHeight)
                }
            }
        }
    }

    // MARK: - Background

    private var welcomeBackground: some View {
        LinearGradient(
            colors: [
                SurfaceGrade.base,
                Color(hex: "080D1D"),
                SurfaceGrade.base
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    // MARK: - Hero

    private func heroSection(compact: Bool, narrow: Bool) -> some View {
        let logoSize: CGFloat = compact ? 44 : 52
        let titleSize: CGFloat = compact ? 21 : 25

        return HStack(alignment: .center, spacing: AppSpace.lg) {
            BrandLogo(size: logoSize)
                .shadow(color: Brand.primary.opacity(0.32), radius: 14, y: 0)

            VStack(alignment: narrow ? .center : .leading, spacing: compact ? 6 : 8) {
                Text("有什么我能帮你的？")
                    .font(.system(size: titleSize, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [TextGrade.primary, TextGrade.secondary],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                Text("把目标、文件或截图放进来，来财会判断该聊天、搜索、读代码还是直接动手。")
                    .font(.system(size: compact ? 12 : 14, weight: .regular))
                    .foregroundStyle(TextGrade.muted)
                    .multilineTextAlignment(narrow ? .center : .leading)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: narrow ? .center : .leading)
        }
        .frame(maxWidth: .infinity, alignment: narrow ? .center : .leading)
        .padding(.horizontal, narrow ? 0 : AppSpace.sm)
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

    // MARK: - Hints

    @ViewBuilder
    private func welcomeHints(narrow: Bool) -> some View {
        if narrow {
            VStack(spacing: AppSpace.sm) { hintItems }
        } else {
            HStack(spacing: AppSpace.md) { hintItems }
        }
    }

    private var hintItems: some View {
        Group {
            KeyHint(keys: "⌘K", desc: "命令")
            KeyHint(keys: "拖入", desc: "文件夹")
            KeyHint(keys: "⌘V", desc: "图片")
            KeyHint(keys: "⇧↵", desc: "换行")
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
