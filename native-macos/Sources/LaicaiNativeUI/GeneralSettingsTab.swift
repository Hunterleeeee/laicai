import LaicaiNativeDomain
import LaicaiNativeFoundation
import SwiftUI

struct GeneralSettingsTab: View {
    @EnvironmentObject private var store: AppStore
    @State private var overviewTotals = UsageTotals()
    @State private var overviewLoadTask: Task<Void, Never>?
    @State private var workspacePathDraft = ""
    @State private var vaultPathDraft = ""
    @State private var pathCommitTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpace.large) {
                aboutCard
                appearanceCard
                workspaceCard
                defaultModelCard
                dataCard
            }
            .padding(AppSpace.extraLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { loadOverview() }
        .onAppear {
            // Sync drafts once so typing does not trigger engine re-init
            // (which updateWorkspacePath would do) on every keystroke.
            workspacePathDraft = store.state.settings.workspacePath
            vaultPathDraft = store.state.settings.vaultPath
        }
    }

    /// Commit path edits only after the user pauses typing. This keeps
    /// `updateWorkspacePath` (which restarts workspace engines) from firing
    /// on every keystroke.
    private func schedulePathCommit(_ value: String, commit: @escaping (String) -> Void) {
        pathCommitTask?.cancel()
        pathCommitTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            commit(value)
        }
    }

    private func loadOverview() {
        overviewLoadTask?.cancel()
        let tracker = UsageTracker.shared
        overviewLoadTask = Task {
            let totals = await Task.detached(priority: .utility) { tracker.totals(days: 9999) }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                overviewTotals = totals
            }
        }
    }

    private var appearanceCard: some View {
        settingsCard(title: "外观") {
            settingsRow(label: "主题") {
                Picker(
                    "",
                    selection: Binding(
                        get: { store.state.settings.appearance },
                        set: { store.updateAppearance($0) }
                    )
                ) {
                    Text("浅色").tag(ThemeAppearance.light)
                    Text("深色").tag(ThemeAppearance.dark)
                }
                .labelsHidden()
                .frame(maxWidth: 200, alignment: .leading)
                .help("手动选择界面配色；色板本身已支持浅色/深色两套。")
            }
        }
    }

    private var workspaceCard: some View {
        settingsCard(title: "工作区") {
            settingsRow(label: "路径") {
                TextField(
                    "选择本地项目或资料目录",
                    text: $workspacePathDraft
                )
                .textFieldStyle(.roundedBorder)
                .onChange(of: workspacePathDraft) { _, newValue in
                    schedulePathCommit(newValue) { store.updateWorkspacePath($0) }
                }
                Button("浏览") { chooseDirectory { path in
                    workspacePathDraft = path
                    store.updateWorkspacePath(path)
                } }
                    .buttonStyle(.bordered)
            }

            settingsRow(label: "知识库") {
                TextField(
                    "Obsidian 知识库路径；留空则使用工作区",
                    text: $vaultPathDraft
                )
                .textFieldStyle(.roundedBorder)
                .onChange(of: vaultPathDraft) { _, newValue in
                    schedulePathCommit(newValue) { store.updateVaultPath($0) }
                }
                Button("浏览") { chooseDirectory { path in
                    vaultPathDraft = path
                    store.updateVaultPath(path)
                } }
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
        let totals = overviewTotals
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
