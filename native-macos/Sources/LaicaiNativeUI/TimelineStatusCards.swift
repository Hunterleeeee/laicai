import AppKit
import LaicaiNativeDomain
import LaicaiNativeFoundation
import SwiftUI

// MARK: - Paused Card (soft interruption / recoverable)

struct PausedCard: View {
    @EnvironmentObject private var store: AppStore
    let step: TaskStep
    let taskID: UUID

    var body: some View {
        HStack(alignment: .top, spacing: AppSpace.small) {
            AvatarBadge(icon: "pause.circle.fill", color: Semantic.warning)

            VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
                Text("已暂停，可继续")
                    .font(AppFont.captionMedium)
                    .foregroundStyle(Semantic.warning)

                Text(diagnosisText)
                    .font(AppFont.body)
                    .foregroundStyle(TextGrade.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                HStack(spacing: AppSpace.small) {
                    Button {
                        store.continueThread(id: taskID)
                    } label: {
                        Label("继续会话", systemImage: "play.fill")
                            .font(AppFont.captionMedium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, AppSpace.medium)
                            .padding(.vertical, AppSpace.small)
                            .background(Capsule().fill(Brand.primary))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, AppSpace.large)
            .padding(.vertical, AppSpace.medium)
            .frame(maxWidth: 560, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                    .fill(Semantic.warningMuted.opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
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
        HStack(alignment: .top, spacing: AppSpace.small) {
            AvatarBadge(icon: "exclamationmark.triangle.fill", color: Semantic.error)

            VStack(alignment: .leading, spacing: AppSpace.small) {
                HStack(spacing: AppSpace.small) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failureTitle)
                            .font(AppFont.captionMedium)
                            .foregroundStyle(Semantic.error)
                        Text(failureHint)
                            .font(AppFont.tiny)
                            .foregroundStyle(TextGrade.ghost)
                            .lineLimit(2)
                    }
                    Spacer(minLength: AppSpace.small)
                    Text(failureKindLabel)
                        .font(AppFont.tiny)
                        .foregroundStyle(Semantic.error)
                        .padding(.horizontal, AppSpace.small)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Semantic.errorMuted.opacity(0.55)))
                }

                Text(step.text)
                    .font(AppFont.body)
                    .foregroundStyle(TextGrade.secondary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                HStack(spacing: AppSpace.small) {
                    failureAction(icon: "arrow.clockwise", label: "重试", isPrimary: true) {
                        store.retryLastMessage()
                    }

                    if shouldOpenSettings {
                        failureAction(icon: "gearshape", label: settingsActionTitle) {
                            NotificationCenter.default.post(name: .laicaiOpenSettings, object: nil)
                        }
                    }

                    failureAction(icon: "doc.on.doc", label: "复制详情") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(step.text, forType: .string)
                        ToastCenter.shared.success("已复制详情")
                    }
                }
            }
            .padding(.horizontal, AppSpace.large)
            .padding(.vertical, AppSpace.medium)
            .frame(maxWidth: 560, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                    .fill(Semantic.errorMuted.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
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
        if isImageFailure { return "可以先重试；若连续失败，检查图片模型、代理或网关。" }
        if isNetworkFailure { return "连接中途断开，可以直接重试或检查代理/网关。" }
        if isAuthFailure { return "API Key、模型名或兼容接口配置可能不正确。" }
        if isWorkspaceFailure { return "工作区目录为空、过宽或无权限。" }
        if step.text.contains("超时") { return "会话可能仍在服务端排队，可以重试或换更快模型。" }
        return "已保留详情，可复制后继续排查。"
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
        step.text.contains("图片") || step.text.localizedCaseInsensitiveContains("image.generate")
            || step.text.localizedCaseInsensitiveContains("gpt-image")
    }

    private var isNetworkFailure: Bool {
        step.text.contains("网络") || step.text.contains("连接") || step.text.localizedCaseInsensitiveContains("networkConnectionLost")
            || step.text.localizedCaseInsensitiveContains("timed out")
    }

    private var isAuthFailure: Bool {
        step.text.contains("鉴权") || step.text.contains("401") || step.text.localizedCaseInsensitiveContains("API key")
            || step.text.localizedCaseInsensitiveContains("unauthorized")
    }

    private var isWorkspaceFailure: Bool {
        step.text.contains("工作区") || step.text.localizedCaseInsensitiveContains("workspace")
    }

    private func failureAction(icon: String, label: String, isPrimary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(AppFont.captionMedium)
                .foregroundStyle(isPrimary ? Color.white : TextGrade.secondary)
                .padding(.horizontal, AppSpace.medium)
                .padding(.vertical, AppSpace.small)
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
            isExpanded.toggle()
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
            .padding(.horizontal, AppSpace.small)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)

        if isExpanded {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(TextGrade.muted.opacity(0.7))
                .textSelection(.enabled)
                .padding(.horizontal, AppSpace.medium)
                .padding(.vertical, AppSpace.extraSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                        .fill(Brand.purple.opacity(0.03))
                )
                .padding(.horizontal, AppSpace.small)
        }
    }
}
