import AppKit
import SwiftUI

// ═══════════════════════════════════════════════════════════════
//  来财 Design System v14 — QUIET DESKTOP
//  ‧ Real light/dark adaptive colors via NSColor dynamic providers
//  ‧ Light gray navigation, white canvas, graphite text, restrained accents
//  ‧ Layout tokens prioritize a readable center canvas over decorative chrome
// ═══════════════════════════════════════════════════════════════

// MARK: - Adaptive Color Helpers

extension Color {
    /// Adaptive color that resolves per appearance. Both inputs are sRGB.
    init(light: Color, dark: Color) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                let isDark =
                    appearance.bestMatch(from: [
                        .darkAqua,
                        .vibrantDark,
                        .accessibilityHighContrastDarkAqua,
                        .accessibilityHighContrastVibrantDark,
                    ]) != nil
                return NSColor(isDark ? dark : light)
            })
    }
}

private func hex(_ value: String) -> Color { Color(hex: value) }

// MARK: - Brand
// Neutral desktop colors with one clear action accent.
// Color is used as hierarchy, not wallpaper.

struct Brand {
    static let primary = Color(
        light: hex("2563EB"),
        dark: hex("8FB4FF")
    )
    static let primaryDark = Color(
        light: hex("1747B8"),
        dark: hex("B7CCFF")
    )
    static let primaryMuted = Color(
        light: hex("EAF1FF"),
        dark: hex("1B2742")
    )
    static let primaryHover = Color(
        light: hex("1D4ED8"),
        dark: hex("A8C3FF")
    )
    static let primaryLight = Color(
        light: hex("7AA2FF"),
        dark: hex("D4E1FF")
    )

    static let purple = Color(
        light: hex("7C3AED"),
        dark: hex("C4B5FD")
    )
    static let purpleMuted = Color(
        light: hex("F2EEFF"),
        dark: hex("2B2244")
    )

    static let teal = Color(
        light: hex("0F766E"),
        dark: hex("7DD3C7")
    )
    static let tealMuted = Color(
        light: hex("E7F7F4"),
        dark: hex("173B38")
    )

    static let jade = Color(
        light: hex("10B981"),
        dark: hex("86EFAC")
    )
    static let jadeMuted = Color(
        light: hex("E9FBF3"),
        dark: hex("173729")
    )

    static let gradientStart = primary
    static let gradientEnd = jade

    static let premiumGradient = LinearGradient(
        colors: [primary, primaryLight],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Very gentle wash used behind the welcome hero only.
    static let subtleGradient = LinearGradient(
        colors: [
            Color(light: hex("FFFFFF"), dark: hex("15171C")).opacity(0.0),
            Color(light: hex("F3F6FC"), dark: hex("1E2430")).opacity(0.42),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static var accent: Color { Color.accentColor }
}

// MARK: - Semantic Colors

struct Semantic {
    static let success = Color(
        light: hex("059669"),
        dark: hex("34D399")
    )
    static let successMuted = Color(
        light: hex("D1FAE5"),
        dark: hex("0F3D2C")
    )
    static let warning = Color(
        light: hex("C2670A"),
        dark: hex("F0AB4C")
    )
    static let warningMuted = Color(
        light: hex("FCEFD7"),
        dark: hex("3A2A12")
    )
    static let error = Color(
        light: hex("DC2626"),
        dark: hex("F87171")
    )
    static let errorMuted = Color(
        light: hex("FDE3E3"),
        dark: hex("3F1818")
    )

    static let purpleMuted = Brand.purpleMuted
    static let info = Brand.primary
    static let infoMuted = Brand.primaryMuted

    static var userBubble: Color {
        Color(light: hex("F3F6FB"), dark: hex("202735"))
    }
    static var assistantBubble: Color { Color.clear }
    static var thinkingBubble: Color { Brand.purpleMuted }

    static let toolCall = Color(
        light: hex("64748B"),
        dark: hex("CBD5E1")
    )
    static let toolResult = Color(
        light: hex("475569"),
        dark: hex("AAB6C7")
    )
    static let toolRunning = Brand.jade
}

// MARK: - Text — four steps, no more

struct TextGrade {
    static var primary: Color {
        Color(light: hex("111827"), dark: hex("F8FAFC"))
    }
    static var secondary: Color {
        Color(light: hex("374151"), dark: hex("D1D5DB"))
    }
    static var muted: Color {
        Color(light: hex("6B7280"), dark: hex("9CA3AF"))
    }
    static var ghost: Color {
        Color(light: hex("9CA3AF"), dark: hex("6B7280"))
    }
    static var inverted: Color { Color.white }
}

// MARK: - Surface — white canvas, light gray chrome, low-contrast separators.

struct SurfaceGrade {
    static var base: Color {
        Color(light: hex("FFFFFF"), dark: hex("111318"))
    }
    static var panel: Color {
        Color(light: hex("F4F6FA"), dark: hex("181C23"))
    }
    static var card: Color {
        Color(light: hex("FFFFFF"), dark: hex("20242D"))
    }
    static var elevated: Color {
        Color(light: hex("F8FAFC"), dark: hex("252A34"))
    }
    static var sunken: Color {
        Color(light: hex("ECEFF5"), dark: hex("0D1016"))
    }
    /// Translucent overlay — used for popovers and command palette.
    static var glass: Color {
        Color(
            light: hex("FFFFFF").opacity(0.78),
            dark: hex("222733").opacity(0.92))
    }

    static var hover: Color {
        Color(
            light: Color.black.opacity(0.04),
            dark: Color.white.opacity(0.06))
    }
    static var selected: Color {
        Color(light: hex("E9EDF6"), dark: hex("253149"))
    }
    static var pressed: Color {
        Color(
            light: Color.black.opacity(0.07),
            dark: Color.white.opacity(0.10))
    }
    static var active: Color { Brand.primary.opacity(0.10) }

    static var divider: Color {
        Color(light: hex("E3E7EF"), dark: hex("000000").opacity(0.46))
    }
    static var hairline: Color {
        Color(light: hex("EAEDF3"), dark: hex("FFFFFF").opacity(0.08))
    }
    static var ring: Color {
        Color(light: hex("C6CEDA"), dark: hex("4B5563"))
    }
    static var focusRing: Color { Brand.primary.opacity(0.42) }
    static var border: Color {
        Color(light: hex("D8DEE8"), dark: hex("FFFFFF").opacity(0.11))
    }
}

// MARK: - Typography
// Tight ladder using system defaults. Sizes follow macOS HIG.

struct AppFont {
    static let largeTitle = Font.system(size: 26, weight: .bold)
    static let title = Font.system(size: 17, weight: .semibold)
    static let headline = Font.system(size: 13, weight: .semibold)
    static let subheadline = Font.system(size: 12, weight: .semibold)

    static let body = Font.system(size: 13, weight: .regular)
    static let bodyMedium = Font.system(size: 13, weight: .medium)

    static let caption = Font.system(size: 11, weight: .regular)
    static let captionMedium = Font.system(size: 11, weight: .medium)
    static let tiny = Font.system(size: 10, weight: .regular)
    static let micro = Font.system(size: 9, weight: .medium)

    static let bubbleBody = Font.system(size: 13.5, weight: .regular)
    static let bubbleCaption = Font.system(size: 10, weight: .regular)

    static let code = Font.system(size: 12, weight: .regular, design: .monospaced)
    static let codeSmall = Font.system(size: 10.5, weight: .regular, design: .monospaced)

    static let statusBar = Font.system(size: 11, weight: .regular)
    static let threadRail = Font.system(size: 11, weight: .semibold, design: .rounded)
}

// MARK: - Spacing — 4pt grid, capped at 8 steps

struct AppSpace {
    static let xxs: CGFloat = 2
    static let extraSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let extraLarge: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
}

// MARK: - Radius — three real choices

struct AppRadius {
    static let extraSmall: CGFloat = 4
    static let small: CGFloat = 6
    static let medium: CGFloat = 8
    static let large: CGFloat = 10
    static let extraLarge: CGFloat = 12
    static let xxl: CGFloat = 14
    static let pill: CGFloat = 999
}

// MARK: - Shadow — calmer values; dark mode keeps them barely-there

struct AppShadow {
    static let small = Shadow(color: Color.black.opacity(0.045), radius: 4, yOffset: 2)
    static let card = Shadow(color: Color.black.opacity(0.065), radius: 14, yOffset: 6)
    static let toast = Shadow(color: Color.black.opacity(0.18), radius: 18, yOffset: 10)
    static let bubble = Shadow(color: Color.black.opacity(0.045), radius: 6, yOffset: 2)
    static let glow = Shadow(color: Brand.primary.opacity(0.12), radius: 12, yOffset: 0)
    static let deep = Shadow(color: Color.black.opacity(0.16), radius: 30, yOffset: 16)
    static let ambient = Shadow(color: Color.black.opacity(0.055), radius: 36, yOffset: 0)
}

struct Shadow {
    let color: Color
    let radius: CGFloat
    let verticalOffset: CGFloat

    init(color: Color, radius: CGFloat, yOffset: CGFloat) {
        self.color = color
        self.radius = radius
        self.verticalOffset = yOffset
    }
}

// MARK: - Animation

struct AppAnimation {
    static let quick = SwiftUI.Animation.easeOut(duration: 0.12)
    static let standard = SwiftUI.Animation.easeInOut(duration: 0.2)
    static let spring = SwiftUI.Animation.spring(response: 0.32, dampingFraction: 0.85)
    static let gentle = SwiftUI.Animation.easeInOut(duration: 0.3)
    static let smooth = SwiftUI.Animation.spring(response: 0.5, dampingFraction: 0.88)
    static let bounce = SwiftUI.Animation.spring(response: 0.4, dampingFraction: 0.65)
    static let micro = SwiftUI.Animation.easeOut(duration: 0.08)
}

// MARK: - Layout Constants

struct LayoutConst {
    static let threadRailWidth: CGFloat = 64
    static let threadRailExpandedWidth: CGFloat = 230
    static let statusBarHeight: CGFloat = 22
    static let commandBarHeight: CGFloat = 38
    static let conversationMaxWidth: CGFloat = 760
    static let composerMaxWidth: CGFloat = 720
    static let composerCornerRadius: CGFloat = 12
    static let toolbarHeight: CGFloat = 44

    /// Hidden title bar + fullSizeContentView: keep toolbar clear of traffic lights.
    static let windowChromeLeadingInset: CGFloat = 76

    static let workbenchPanelMinWidth: CGFloat = 300
    static let workbenchPanelIdealWidth: CGFloat = 316
    static let workbenchPanelMaxWidth: CGFloat = 368
}

// MARK: - View Extensions

extension View {
    /// Standard surface card: 1 hairline border, very faint shadow.
    func cardStyle(cornerRadius: CGFloat = AppRadius.extraLarge) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(SurfaceGrade.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(SurfaceGrade.hairline, lineWidth: 0.7)
            )
    }

    /// Floating popover-style surface with a touch more elevation.
    func glassCard(cornerRadius: CGFloat = AppRadius.extraLarge) -> some View {
        self
            .background(SurfaceGrade.glass)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(SurfaceGrade.border.opacity(0.5), lineWidth: 0.5)
            )
            .shadow(color: AppShadow.card.color, radius: AppShadow.card.radius, y: AppShadow.card.verticalOffset)
    }

    /// Chat bubble — neutral surface, user variant gets the brand tint.
    func bubbleStyle(isUser: Bool = false) -> some View {
        self
            .background(
                isUser
                    ? AnyShapeStyle(Semantic.userBubble)
                    : AnyShapeStyle(SurfaceGrade.card)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.extraLarge, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.extraLarge, style: .continuous)
                    .strokeBorder(
                        isUser ? Brand.primary.opacity(0.22) : SurfaceGrade.hairline,
                        lineWidth: 0.6
                    )
            )
    }

    /// Pill — small tagged label.
    func pillStyle(color: Color = Brand.primary) -> some View {
        self
            .font(AppFont.captionMedium)
            .foregroundStyle(color)
            .padding(.horizontal, AppSpace.small + 2)
            .padding(.vertical, AppSpace.extraSmall + 1)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
            )
    }

    func subtleGlow(color: Color = Brand.primary, radius: CGFloat = 24) -> some View {
        self.shadow(color: color.opacity(0.15), radius: radius, y: 0)
    }

    func innerShadow(color: Color = .black.opacity(0.4), radius: CGFloat = 4) -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .stroke(color, lineWidth: 2)
                .blur(radius: radius)
                .mask(
                    RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.black, .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            ))
                )
        )
    }

    /// Command palette / popover surface.
    func commandSurface() -> some View {
        self
            .background(SurfaceGrade.glass)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.xxl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.xxl, style: .continuous)
                    .strokeBorder(SurfaceGrade.border.opacity(0.55), lineWidth: 0.5)
            )
            .shadow(color: AppShadow.deep.color, radius: AppShadow.deep.radius, y: AppShadow.deep.verticalOffset)
    }

    /// Sidebar list row treatment.
    func threadRailItem(isSelected: Bool = false, isHovering: Bool = false) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(
                        isSelected
                            ? SurfaceGrade.selected
                            : (isHovering ? SurfaceGrade.hover : Color.clear)
                    )
            )
    }

    func statusBarStyle() -> some View {
        self
            .font(AppFont.statusBar)
            .foregroundStyle(TextGrade.muted)
    }
}

// MARK: - Shared Utilities

enum TextHelper {
    static func compactTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host else { return trimmed }
        let leaf = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return leaf.isEmpty ? host : "\(host)/\(leaf)"
    }
}

// MARK: - Color Hex Init

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let alphaComponent: UInt64
        let redComponent: UInt64
        let greenComponent: UInt64
        let blueComponent: UInt64
        switch hex.count {
        case 3:
            alphaComponent = 255
            redComponent = (int >> 8) * 17
            greenComponent = (int >> 4 & 0xF) * 17
            blueComponent = (int & 0xF) * 17
        case 6:
            alphaComponent = 255
            redComponent = int >> 16
            greenComponent = int >> 8 & 0xFF
            blueComponent = int & 0xFF
        case 8:
            alphaComponent = int >> 24
            redComponent = int >> 16 & 0xFF
            greenComponent = int >> 8 & 0xFF
            blueComponent = int & 0xFF
        default:
            alphaComponent = 255
            redComponent = 0
            greenComponent = 0
            blueComponent = 0
        }
        self.init(
            .sRGB,
            red: Double(redComponent) / 255,
            green: Double(greenComponent) / 255,
            blue: Double(blueComponent) / 255,
            opacity: Double(alphaComponent) / 255
        )
    }
}

// MARK: - Brand Logo

/// Reusable brand logo at any size.
struct BrandLogo: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            if let image = NSImage(named: "laicai-logo") ?? Bundle.main.image(forResource: "laicai-logo") {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                fallbackLogo
            }
        }
        .frame(width: size, height: size)
    }

    private var fallbackLogo: some View {
        let corner = size * 0.23
        let stroke = max(3, size * 0.12)

        return ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [hex("2E6E91"), hex("0F334E"), hex("071D31")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Image(systemName: "infinity")
                .font(.system(size: size * 0.64, weight: .heavy))
                .foregroundStyle(
                    LinearGradient(
                        colors: [hex("F7FEFF"), hex("A8C0C9"), hex("EAF7FA")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .black.opacity(0.45), radius: stroke * 0.18, y: stroke * 0.12)
        }
    }
}
