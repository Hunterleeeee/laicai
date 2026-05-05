import SwiftUI

// MARK: - Toast Data Model

enum ToastStyle: Equatable {
    case info
    case success
    case warning
    case error

    var color: Color {
        switch self {
        case .info: return Brand.primary
        case .success: return Semantic.success
        case .warning: return Semantic.warning
        case .error: return Semantic.error
        }
    }

    var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }
}

struct ToastItem: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let style: ToastStyle
}

// MARK: - Toast Center

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published var current: ToastItem?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ message: String, style: ToastStyle = .info, autoDismiss: Bool = true) {
        dismissTask?.cancel()
        withAnimation(AppAnimation.quick) {
            current = ToastItem(message: message, style: style)
        }
        if autoDismiss {
            dismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.8))
                guard !Task.isCancelled else { return }
                withAnimation(AppAnimation.quick) {
                    self?.current = nil
                }
            }
        }
    }

    func success(_ message: String) { show(message, style: .success) }
    func error(_ message: String) { show(message, style: .error) }
    func warn(_ message: String) { show(message, style: .warning) }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(AppAnimation.quick) {
            current = nil
        }
    }
}

// MARK: - Toast Overlay

struct ToastOverlay: View {
    @ObservedObject private var center = ToastCenter.shared

    var body: some View {
        if let toast = center.current {
            HStack(spacing: AppSpace.sm) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(toast.style.color)
                    .frame(width: 3, height: 16)

                Image(systemName: toast.style.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(toast.style.color)

                Text(toast.message)
                    .font(AppFont.body)
                    .foregroundStyle(TextGrade.primary)
                    .lineLimit(2)
            }
            .padding(.horizontal, AppSpace.lg)
            .padding(.vertical, AppSpace.sm + 2)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .strokeBorder(SurfaceGrade.border.opacity(0.4), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onTapGesture { center.dismiss() }
        }
    }
}
