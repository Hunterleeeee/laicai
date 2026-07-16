import LaicaiNativeDomain
import LaicaiNativeFoundation
import SwiftUI

struct GeneralSettingsTab: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpace.large) {
                aboutCard
                workspaceCard
                defaultModelCard
                dataCard
            }
            .padding(AppSpace.extraLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var workspaceCard: some View {
        settingsCard(title: "工作区") {
            settingsRow(label: "路径") {
                TextField(
                    "选择本地项目或资料目录",
                    text: Binding(
                        get: { store.state.settings.workspacePath },
                        set: { store.updateWorkspacePath($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                Button("浏览") { chooseDirectory(store.updateWorkspacePath) }
                    .buttonStyle(.bordered)
            }

            settingsRow(label: "知识库") {
                TextField(
                    "Obsidian 知识库路径；留空则使用工作区",
                    text: Binding(
                        get: { store.state.settings.vaultPath },
                        set: { store.updateVaultPath($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                Button("浏览") { chooseDirectory(store.updateVaultPath) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var defaultModelCard: some View {
        settingsCard(title: "默认模型") {
            settingsRow(label: "连接器") {
                Picker(
                    "",
                    selection: Binding(
                        get: { store.state.activeConnectorID ?? UUID() },
                        set: { store.selectConnector(id: $0) }
                    )
                ) {
                    Text("无").tag(UUID())
                    ForEach(store.state.connectors) { connector in
                        Text(connector.name).tag(connector.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260, alignment: .leading)
            }
        }
    }

    private var aboutCard: some View {
        HStack(spacing: AppSpace.large) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Brand.subtleGradient)
                    .frame(width: 48, height: 48)
                Image(systemName: "sparkle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Brand.primary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("来财 Laicai")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(TextGrade.primary)
                Text("macOS 本机 AI 编排助手")
                    .font(.system(size: 11))
                    .foregroundStyle(TextGrade.muted)
                Text(appVersionLabel)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(TextGrade.ghost)
            }
            Spacer()
        }
        .padding(AppSpace.large)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(SurfaceGrade.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .strokeBorder(Brand.primary.opacity(0.15), lineWidth: 0.5)
        )
    }

    private var dataCard: some View {
        let totals = UsageTracker.shared.totals(days: 9999)
        let threadCount = store.state.threads.count
        let projectCount = ProjectManager.shared.projects.count

        return settingsCard(title: "数据概览") {
            HStack(spacing: AppSpace.extraLarge) {
                statPill(value: "\(projectCount)", label: "项目")
                statPill(value: "\(threadCount)", label: "对话")
                statPill(value: "\(totals.requestCount)", label: "请求")
                statPill(value: formatCostBrief(totals.estimatedCost), label: "费用")
            }
        }
    }

    private func statPill(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(TextGrade.primary)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(TextGrade.ghost)
        }
    }

    private func formatCostBrief(_ cost: Double) -> String {
        if cost < 1 { return String(format: "¥%.2f", cost * 7.2) }
        return String(format: "$%.1f", cost)
    }

    private func chooseDirectory(_ update: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            update(url.path)
        }
    }
}
