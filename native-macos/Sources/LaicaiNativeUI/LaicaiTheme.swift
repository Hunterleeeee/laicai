import SwiftUI

// ═══════════════════════════════════════════════════════════════
//  来财 Design System v5 — MISSION CONTROL
//  Deep-space dark theme with ambient intelligence,
//  glass morphism, living status colors, and spatial depth.
//  Designed for an AI orchestration command center.
// ═══════════════════════════════════════════════════════════════

// MARK: - Brand Colors

struct Brand {
    static let primary = Color(hex: "3B82F6")
    static let primaryDark = Color(hex: "2563EB")
    static let primaryMuted = Color(hex: "172554")
    static let primaryHover = Color(hex: "60A5FA")
    static let primaryLight = Color(hex: "93C5FD")

    static let purple = Color(hex: "8B5CF6")
    static let purpleMuted = Color(hex: "1E1338")

    static let teal = Color(hex: "06B6D4")
    static let tealMuted = Color(hex: "0C2D3F")

    static let gradientStart = Color(hex: "3B82F6")
    static let gradientEnd = Color(hex: "8B5CF6")

    static let premiumGradient = LinearGradient(
        colors: [Color(hex: "3B82F6"), Color(hex: "6366F1"), Color(hex: "8B5CF6")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let subtleGradient = LinearGradient(
        colors: [Color(hex: "3B82F6").opacity(0.15), Color(hex: "8B5CF6").opacity(0.15)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static var accent: Color { Color.accentColor }
}

// MARK: - Semantic Colors

struct Semantic {
    static let success = Color(hex: "10B981")
    static let successMuted = Color(hex: "052E1C")
    static let warning = Color(hex: "F59E0B")
    static let warningMuted = Color(hex: "2D1F04")
    static let error = Color(hex: "EF4444")
    static let errorMuted = Color(hex: "2D0A0A")
    static let purpleMuted = Brand.purpleMuted
    static let info = Brand.primary
    static let infoMuted = Brand.primaryMuted

    static var userBubble: Color { Color(hex: "1E293B") }
    static var assistantBubble: Color { Color.clear }
    static var thinkingBubble: Color { Brand.purpleMuted }

    static let toolCall = Color(hex: "F59E0B")
    static let toolResult = Color(hex: "64748B")
    static let toolRunning = Brand.teal
}

// MARK: - Text Colors

struct TextGrade {
    static var primary: Color { Color(hex: "F8FAFC") }
    static var secondary: Color { Color(hex: "94A3B8") }
    static var muted: Color { Color(hex: "64748B") }
    static var ghost: Color { Color(hex: "475569") }
    static var inverted: Color { Color(hex: "0F172A") }
}

// MARK: - Surface System — Deep Space Layers

struct SurfaceGrade {
    static var base: Color { Color(hex: "020617") }      // Deepest void — slate-950
    static var panel: Color { Color(hex: "0F172A") }     // Sidebar — slate-900
    static var card: Color { Color(hex: "1E293B") }      // Cards — slate-800
    static var elevated: Color { Color(hex: "334155") }   // Elevated — slate-700
    static var sunken: Color { Color(hex: "020617") }     // Sunken = abyss
    static var glass: Color { Color(hex: "1E293B").opacity(0.8) }

    static var hover: Color { Color.white.opacity(0.05) }
    static var selected: Color { Brand.primary.opacity(0.12) }
    static var pressed: Color { Color.white.opacity(0.03) }
    static var active: Color { Brand.primary.opacity(0.08) }

    static var divider: Color { Color(hex: "334155").opacity(0.6) }
    static var hairline: Color { Color.white.opacity(0.06) }
    static var ring: Color { Color(hex: "475569") }
    static var focusRing: Color { Brand.primary.opacity(0.50) }
    static var border: Color { Color(hex: "334155") }
}

// MARK: - Typography — Clean & Functional

struct AppFont {
    static let largeTitle = Font.system(size: 26, weight: .bold, design: .rounded)
    static let title = Font.system(size: 18, weight: .semibold)
    static let headline = Font.system(size: 14, weight: .semibold)
    static let subheadline = Font.system(size: 12, weight: .semibold)

    static let body = Font.system(size: 13, weight: .regular)
    static let bodyMedium = Font.system(size: 13, weight: .medium)

    static let caption = Font.system(size: 11, weight: .regular)
    static let captionMedium = Font.system(size: 11, weight: .medium)
    static let tiny = Font.system(size: 10, weight: .regular)
    static let micro = Font.system(size: 9, weight: .medium)

    static let bubbleBody = Font.system(size: 13.5, weight: .regular)
    static let bubbleCaption = Font.system(size: 9, weight: .regular)

    static let code = Font.system(size: 12, weight: .regular, design: .monospaced)
    static let codeSmall = Font.system(size: 10.5, weight: .regular, design: .monospaced)

    static let statusBar = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let threadRail = Font.system(size: 10, weight: .bold, design: .rounded)
}

// MARK: - Spacing

struct AppSpace {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
}

// MARK: - Corner Radius — Refined

struct AppRadius {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 20
    static let pill: CGFloat = 999
}

// MARK: - Shadows — Subtle Depth

struct AppShadow {
    static let sm = Shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    static let card = Shadow(color: .black.opacity(0.40), radius: 16, y: 8)
    static let toast = Shadow(color: .black.opacity(0.50), radius: 24, y: 12)
    static let bubble = Shadow(color: .black.opacity(0.20), radius: 6, y: 3)
    static let glow = Shadow(color: Brand.primary.opacity(0.25), radius: 20, y: 0)
    static let deep = Shadow(color: .black.opacity(0.60), radius: 40, y: 20)
    static let ambient = Shadow(color: Brand.primary.opacity(0.10), radius: 40, y: 0)
}

struct Shadow {
    let color: Color
    let radius: CGFloat
    let y: CGFloat
}

// MARK: - Animation

struct AppAnimation {
    static let quick = SwiftUI.Animation.easeOut(duration: 0.12)
    static let standard = SwiftUI.Animation.easeInOut(duration: 0.2)
    static let spring = SwiftUI.Animation.spring(response: 0.35, dampingFraction: 0.8)
    static let gentle = SwiftUI.Animation.easeInOut(duration: 0.35)
    static let smooth = SwiftUI.Animation.spring(response: 0.5, dampingFraction: 0.85)
    static let bounce = SwiftUI.Animation.spring(response: 0.4, dampingFraction: 0.65)
    static let micro = SwiftUI.Animation.easeOut(duration: 0.08)
}

// MARK: - Layout Constants

struct LayoutConst {
    static let threadRailWidth: CGFloat = 60
    static let threadRailExpandedWidth: CGFloat = 280
    static let statusBarHeight: CGFloat = 28
    static let commandBarHeight: CGFloat = 40
    static let composerMaxWidth: CGFloat = 720
    static let composerCornerRadius: CGFloat = 16
    static let toolbarHeight: CGFloat = 44
}

// MARK: - View Extensions

extension View {
    func cardStyle() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .fill(SurfaceGrade.card)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .strokeBorder(SurfaceGrade.border.opacity(0.5), lineWidth: 0.5)
            )
    }

    func glassCard(cornerRadius: CGFloat = AppRadius.lg) -> some View {
        self
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
    }

    func bubbleStyle(isUser: Bool = false) -> some View {
        self
            .background(
                isUser
                    ? AnyShapeStyle(Semantic.userBubble)
                    : AnyShapeStyle(.ultraThinMaterial)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .strokeBorder(
                        isUser ? Brand.primary.opacity(0.20) : Color.white.opacity(0.06),
                        lineWidth: 0.5
                    )
            )
    }

    func pillStyle(color: Color = Brand.primary) -> some View {
        self
            .font(AppFont.captionMedium)
            .foregroundStyle(color)
            .padding(.horizontal, AppSpace.sm + 2)
            .padding(.vertical, AppSpace.xs + 1)
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
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .stroke(color, lineWidth: 2)
                .blur(radius: radius)
                .mask(
                    RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                        .fill(LinearGradient(
                            colors: [.black, .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                )
        )
    }

    func commandSurface() -> some View {
        self
            .background(.ultraThickMaterial)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.4), radius: 30, y: 15)
    }

    func threadRailItem(isSelected: Bool = false, isHovering: Bool = false) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .fill(isSelected ? Brand.primary.opacity(0.15) : (isHovering ? SurfaceGrade.hover : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .strokeBorder(isSelected ? Brand.primary.opacity(0.3) : Color.clear, lineWidth: 0.5)
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

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Brand Logo

/// Custom 4-pointed spark shape — elongated vertically with smooth curves.
struct SparkMark: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let cy = rect.midY
        let rx = rect.width / 2
        let ry = rect.height / 2
        let pinch: CGFloat = 0.18

        var p = Path()
        // Top
        p.move(to: CGPoint(x: cx, y: cy - ry))
        // To right
        p.addQuadCurve(
            to: CGPoint(x: cx + rx, y: cy),
            control: CGPoint(x: cx + rx * pinch, y: cy - ry * pinch)
        )
        // To bottom
        p.addQuadCurve(
            to: CGPoint(x: cx, y: cy + ry),
            control: CGPoint(x: cx + rx * pinch, y: cy + ry * pinch)
        )
        // To left
        p.addQuadCurve(
            to: CGPoint(x: cx - rx, y: cy),
            control: CGPoint(x: cx - rx * pinch, y: cy + ry * pinch)
        )
        // Back to top
        p.addQuadCurve(
            to: CGPoint(x: cx, y: cy - ry),
            control: CGPoint(x: cx - rx * pinch, y: cy - ry * pinch)
        )
        return p
    }
}

/// Reusable brand logo at any size.
struct BrandLogo: View {
    let size: CGFloat

    var body: some View {
        let corner = size * 0.24
        let sparkH = size * 0.58
        let sparkW = sparkH * 0.72
        let dotR = max(2, size * 0.05)

        ZStack {
            // Squircle base
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Brand.premiumGradient)
                .frame(width: size, height: size)

            // Subtle inner glow
            RoundedRectangle(cornerRadius: corner * 0.8, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.12), .clear],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: size * 0.7
                    )
                )
                .frame(width: size * 0.92, height: size * 0.92)

            // Main spark mark
            SparkMark()
                .fill(.white.opacity(0.92))
                .frame(width: sparkW, height: sparkH)

            // Small accent dot — top-right of spark
            Circle()
                .fill(.white)
                .frame(width: dotR * 2, height: dotR * 2)
                .offset(x: sparkW * 0.42, y: -sparkH * 0.28)
                .opacity(size >= 40 ? 0.7 : 0)
        }
    }
}
