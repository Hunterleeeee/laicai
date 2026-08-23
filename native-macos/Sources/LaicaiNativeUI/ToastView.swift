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

enum ToastAction: Equatable {
    case undoDelete

    var title: String {
        switch self {
        case .undoDelete: return "撤销"
        }
    }
}

struct ToastItem: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let style: ToastStyle
    let action: ToastAction?
    let autoDismiss: Bool
}

// MARK: - Toast Center

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published var current: ToastItem?
    private var queue: [ToastItem] = []
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ message: String, style: ToastStyle = .info, autoDismiss: Bool = true, action: ToastAction? = nil) {
        let item = ToastItem(message: message, style: style, action: action, autoDismiss: autoDismiss)
        if current != nil {
            queue.append(item)
            return
        }
        present(item, autoDismiss: autoDismiss)
    }

    private func present(_ item: ToastItem, autoDismiss: Bool) {
        dismissTask?.cancel()
        withAnimation(AppAnimation.quick) {
            current = item
        }
        if autoDismiss {
            dismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.8))
                guard !Task.isCancelled else { return }
                self?.dismiss()
            }
        }
    }

    func success(_ message: String) { show(message, style: .success) }
    func error(_ message: String) { show(message, style: .error) }
    func warn(_ message: String) { show(message, style: .warning) }

    func dismiss() {
        dismissTask?.cancel()
        let next = queue.isEmpty ? nil : queue.removeFirst()
        withAnimation(AppAnimation.quick) {
            current = nil
        }
        if let next {
            present(next, autoDismiss: next.autoDismiss)
        }
    }

    func perform(_ action: ToastAction) {
        switch action {
        case .undoDelete:
            NotificationCenter.default.post(name: .laicaiUndoDeleteThread, object: nil)
        }
        dismiss()
    }
}

// MARK: - Toast Overlay

struct ToastOverlay: View {
    @ObservedObject private var center = ToastCenter.shared

    var body: some View {
        if let toast = center.current {
            HStack(spacing: AppSpace.small) {
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
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel(toast.message)
                if let action = toast.action {
                    Button(action.title) { center.perform(action) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, AppSpace.large)
            .padding(.vertical, AppSpace.small + 2)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .strokeBorder(SurfaceGrade.border.opacity(0.4), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(toast.message)
            .onTapGesture { center.dismiss() }
        }
    }
}
