import Foundation
import LaicaiNativeDomain
import LaicaiNativeFoundation
import SwiftUI

// MARK: - Connectors Panel

struct ConnectorsPanel: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingAddSheet = false
    @State private var editingConnector: ConnectorProfile?
    @State private var deletingConnector: ConnectorProfile?
    @State private var isCheckingAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.medium) {
            connectorOverview

            if store.state.connectors.isEmpty {
                emptyHint(
                    icon: "link.badge.plus",
                    title: "暂无连接器",
                    hint: "添加模型 API 或本地 Ollama"
                )
            } else {
                VStack(spacing: AppSpace.small) {
                    ForEach(store.state.connectors) { conn in
                        ConnectorRow(conn: conn)
                            .onTapGesture { store.selectConnector(id: conn.id) }
                            .contextMenu {
                                Button {
                                    store.checkConnectorHealth(id: conn.id)
                                } label: {
                                    Label("健康检查", systemImage: "heart")
                                }
                                if conn.toolCallingCapability != nil {
                                    Button {
                                        store.clearLearnedToolCallingCapability(id: conn.id)
                                    } label: {
                                        Label("清除已学习兼容性", systemImage: "arrow.counterclockwise.circle")
                                    }
                                }
                                Button {
                                    editingConnector = conn
                                } label: {
                                    Label("编辑", systemImage: "pencil")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    deletingConnector = conn
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            ConnectorEditSheet(mode: .add) { conn in
                store.addConnector(conn)
                store.checkAllConnectorsHealth()
                ToastCenter.shared.success("已添加 \(conn.name)")
            } onSaveAndTest: { conn in
                store.addConnector(conn)
                store.checkConnectorHealth(id: conn.id)
                ToastCenter.shared.show("正在测试 \(conn.name)")
            }
        }
        .sheet(item: $editingConnector) { conn in
            ConnectorEditSheet(mode: .edit(conn)) { updated in
                store.updateConnector(updated)
                ToastCenter.shared.success("已更新 \(updated.name)")
            } onSaveAndTest: { updated in
                store.updateConnector(updated)
                store.checkConnectorHealth(id: updated.id)
                ToastCenter.shared.show("正在测试 \(updated.name)")
            }
        }
        .alert(
            "删除连接器",
            isPresented: Binding(
                get: { deletingConnector != nil },
                set: { if !$0 { deletingConnector = nil } }
            )
        ) {
            Button("取消", role: .cancel) { deletingConnector = nil }
            Button("删除", role: .destructive) {
                if let conn = deletingConnector { store.deleteConnector(id: conn.id) }
                deletingConnector = nil
            }
        } message: {
            Text("删除后这个模型配置会从本机移除。")
        }
    }

    private var connectorOverview: some View {
        let online = store.state.connectors.filter { $0.health == .ready }.count
        let total = store.state.connectors.count
        let active = store.state.activeConnector

        return VStack(alignment: .leading, spacing: AppSpace.medium) {
            HStack(alignment: .top, spacing: AppSpace.small) {
                Image(systemName: active?.health == .ready ? "checkmark.seal.fill" : "link")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(active?.health == .ready ? Semantic.success : Brand.primary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill((active?.health == .ready ? Semantic.success : Brand.primary).opacity(0.10)))

                VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
                    Text(
                        active == nil ? "模型连接" : (active?.modelName.isEmpty == false ? active?.modelName ?? "模型连接" : active?.name ?? "模型连接")
                    )
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TextGrade.primary)
                    .lineLimit(1)
                    Text(total == 0 ? "添加模型后即可开始使用。" : "\(online)/\(total) 在线 · 点击下方连接器即可切换")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                        .lineLimit(2)
                }

                Spacer()
            }

            HStack(spacing: AppSpace.extraSmall) {
                Button {
                    isCheckingAll = true
                    store.checkAllConnectorsHealth()
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(3))
                        isCheckingAll = false
                    }
                } label: {
                    Label(isCheckingAll ? "检查中" : "检查", systemImage: isCheckingAll ? "arrow.triangle.2.circlepath" : "heart.text.square")
                        .font(AppFont.captionMedium)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(total == 0 ? TextGrade.ghost : Brand.primary)
                .padding(.vertical, AppSpace.small)
                .background(RoundedRectangle(cornerRadius: AppRadius.medium).fill(SurfaceGrade.card.opacity(0.60)))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.medium).strokeBorder(SurfaceGrade.hairline.opacity(0.8), lineWidth: 0.6))
                .disabled(total == 0)

                Button {
                    showingAddSheet = true
                } label: {
                    Label("添加", systemImage: "plus")
                        .font(AppFont.captionMedium)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.primary)
                .padding(.vertical, AppSpace.small)
                .background(RoundedRectangle(cornerRadius: AppRadius.medium).fill(Brand.primary.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.medium).strokeBorder(Brand.primary.opacity(0.18), lineWidth: 0.6))
            }
        }
        .padding(AppSpace.large)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [SurfaceGrade.card, SurfaceGrade.elevated.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .strokeBorder(SurfaceGrade.hairline.opacity(0.9), lineWidth: 0.7)
        )
        .shadow(color: AppShadow.small.color, radius: AppShadow.small.radius, y: AppShadow.small.verticalOffset)
    }

    private func emptyHint(icon: String, title: String, hint: String) -> some View {
        VStack(spacing: AppSpace.medium) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Brand.primary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Brand.primary.opacity(0.10)))
            VStack(spacing: AppSpace.extraSmall) {
                Text(title)
                    .font(AppFont.captionMedium)
                    .foregroundStyle(TextGrade.secondary)
                Text(hint)
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpace.large)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(SurfaceGrade.card.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .strokeBorder(SurfaceGrade.hairline.opacity(0.75), lineWidth: 0.6)
        )
    }
}

struct ConnectorRow: View {
    let conn: ConnectorProfile
    @EnvironmentObject private var store: AppStore

    var body: some View {
        let capability = ConnectorCapabilityProfile.infer(for: conn, mode: store.state.settings.contextMode)
        HStack(spacing: AppSpace.small) {
            // Status dot with glow
            Circle()
                .fill(conn.health.color)
                .frame(width: 7, height: 7)
                .shadow(color: conn.health.color.opacity(0.5), radius: 3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: AppSpace.extraSmall) {
                    Text(conn.name)
                        .font(AppFont.captionMedium)
                        .foregroundStyle(TextGrade.primary)
                        .lineLimit(1)
                    if conn.id == store.state.activeConnectorID {
                        Text("使用中")
                            .font(AppFont.tiny)
                            .foregroundStyle(Brand.primary)
                    }
                }

                Text(connectorCapabilitySummary(for: conn, capability: capability))
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.muted)
                    .lineLimit(1)
            }

            Spacer()

            Text(conn.health.title)
                .font(AppFont.tiny)
                .foregroundStyle(conn.health == .ready ? Semantic.success : conn.health.color)
                .padding(.horizontal, AppSpace.extraSmall + 2)
                .padding(.vertical, 2)
                .background(Capsule().fill(conn.health.color.opacity(0.10)))
        }
        .padding(AppSpace.medium)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(
                    conn.id == store.state.activeConnectorID
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [Brand.primary.opacity(0.12), SurfaceGrade.card.opacity(0.86)], startPoint: .topLeading,
                                endPoint: .bottomTrailing))
                        : AnyShapeStyle(SurfaceGrade.card.opacity(0.72))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(
                    conn.id == store.state.activeConnectorID ? Brand.primary.opacity(0.24) : SurfaceGrade.hairline.opacity(0.75),
                    lineWidth: 0.7
                )
        )
        .shadow(
            color: conn.id == store.state.activeConnectorID ? AppShadow.small.color : .clear, radius: AppShadow.small.radius,
            y: AppShadow.small.verticalOffset)
    }
}
