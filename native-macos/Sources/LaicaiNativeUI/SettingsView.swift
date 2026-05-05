import SwiftUI
import LaicaiNativeDomain
import LaicaiNativeFoundation

public struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: SettingsTab = .general

    public init() {}

    private enum SettingsTab: String, CaseIterable {
        case general = "通用"
        case connectors = "连接器"
        case gateway = "消息网关"
        case tools = "工具"
        case input = "输入"
        case advanced = "高级"

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .connectors: return "link"
            case .gateway: return "antenna.radiowaves.left.and.right"
            case .tools: return "hammer"
            case .input: return "text.cursor"
            case .advanced: return "slider.horizontal.3"
            }
        }
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Side nav
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsTab.allCases, id: \.rawValue) { tab in
                    let isActive = selectedTab == tab
                    Button {
                        withAnimation(AppAnimation.quick) { selectedTab = tab }
                    } label: {
                        HStack(spacing: AppSpace.sm) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(isActive ? Brand.primary.opacity(0.15) : Color.clear)
                                    .frame(width: 22, height: 22)
                                Image(systemName: tab.icon)
                                    .font(.system(size: 10, weight: isActive ? .semibold : .medium))
                                    .foregroundStyle(isActive ? Brand.primary : TextGrade.ghost)
                            }
                            Text(tab.rawValue)
                                .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                                .foregroundStyle(isActive ? TextGrade.primary : TextGrade.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, AppSpace.sm)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                                .fill(isActive ? SurfaceGrade.hover : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.vertical, AppSpace.lg)
            .padding(.horizontal, AppSpace.sm)
            .frame(width: 136)
            .background(SurfaceGrade.panel)

            Rectangle().fill(SurfaceGrade.divider).frame(width: 1)

            // Content
            VStack(spacing: 0) {
                // Header
                HStack(spacing: AppSpace.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Brand.primary.opacity(0.1))
                            .frame(width: 26, height: 26)
                        Image(systemName: selectedTab.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Brand.primary)
                    }
                    Text(selectedTab.rawValue)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(TextGrade.primary)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(TextGrade.muted)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(SurfaceGrade.elevated))
                    }
                    .buttonStyle(.plain)
                    .help("关闭")
                }
                .padding(.horizontal, AppSpace.xl)
                .padding(.vertical, 14)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(SurfaceGrade.divider).frame(height: 1)
                }

                // Tab content
                Group {
                    switch selectedTab {
                    case .general: GeneralSettingsTab()
                    case .connectors: ConnectorsSettingsTab()
                    case .gateway: GatewaySettingsTab()
                    case .tools: ToolsSettingsTab()
                    case .input: InputSettingsTab()
                    case .advanced: AdvancedSettingsTab()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 700, height: 520)
        .background(SurfaceGrade.base)
    }
}

// MARK: - General Settings

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpace.lg) {
                settingsCard(title: "工作区") {
                    settingsRow(label: "路径") {
                        TextField("选择本地项目或资料目录", text: Binding(
                            get: { store.state.settings.workspacePath },
                            set: { store.updateWorkspacePath($0) }
                        ))
                        .textFieldStyle(.roundedBorder)

                        Button("浏览") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                store.updateWorkspacePath(url.path)
                            }
                        }
                        .buttonStyle(.bordered)
                    }

                    settingsRow(label: "知识库") {
                        TextField("Obsidian 知识库路径；留空则使用工作区", text: Binding(
                            get: { store.state.settings.vaultPath },
                            set: { store.updateVaultPath($0) }
                        ))
                        .textFieldStyle(.roundedBorder)

                        Button("浏览") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                store.updateVaultPath(url.path)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                settingsCard(title: "默认模型") {
                    settingsRow(label: "连接器") {
                        Picker("", selection: Binding(
                            get: { store.state.activeConnectorID ?? UUID() },
                            set: { store.selectConnector(id: $0) }
                        )) {
                            Text("无").tag(UUID())
                            ForEach(store.state.connectors) { c in
                                Text(c.name).tag(c.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260, alignment: .leading)
                    }
                }
            }
            .padding(AppSpace.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}

// MARK: - Connectors Settings

private struct ConnectorsSettingsTab: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingAddSheet = false
    @State private var editingConnector: ConnectorProfile?
    @State private var deletingConnector: ConnectorProfile?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("连接器")
                    .font(AppFont.captionMedium)
                    .foregroundStyle(TextGrade.muted)
                Spacer()
                Button {
                    showingAddSheet = true
                } label: {
                    Label("添加", systemImage: "plus")
                        .font(AppFont.captionMedium)
                        .foregroundStyle(Brand.primary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, AppSpace.xl)
            .padding(.vertical, AppSpace.md)

            Divider()

            if store.state.connectors.isEmpty {
                Spacer()
                VStack(spacing: AppSpace.md) {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 36, weight: .ultraLight))
                        .foregroundStyle(TextGrade.ghost)
                    Text("暂无连接器")
                        .font(AppFont.body)
                        .foregroundStyle(TextGrade.muted)
                    Text("添加模型 API 或本地 Ollama 端点")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.ghost)
                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("添加连接器", systemImage: "plus.circle")
                            .font(AppFont.captionMedium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, AppSpace.lg)
                            .padding(.vertical, AppSpace.sm)
                            .background(Capsule().fill(Brand.primary))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.state.connectors) { conn in
                            ConnectorSettingsRow(
                                conn: conn,
                                onEdit: { editingConnector = conn },
                                onDelete: { deletingConnector = conn }
                            )
                                .onTapGesture { editingConnector = conn }
                            Divider().padding(.leading, AppSpace.xxl)
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
        .alert("删除连接器", isPresented: Binding(
            get: { deletingConnector != nil },
            set: { if !$0 { deletingConnector = nil } }
        )) {
            Button("取消", role: .cancel) { deletingConnector = nil }
            Button("删除", role: .destructive) {
                if let conn = deletingConnector { store.deleteConnector(id: conn.id) }
                deletingConnector = nil
            }
        } message: {
            Text("删除后这个模型配置会从本机移除。")
        }
    }
}

private struct ConnectorSettingsRow: View {
    let conn: ConnectorProfile
    let onEdit: () -> Void
    let onDelete: () -> Void
    @EnvironmentObject private var store: AppStore
    @State private var hovered = false

    var body: some View {
        let capability = ConnectorCapabilityProfile.infer(for: conn, mode: store.state.settings.contextMode)
        HStack(spacing: AppSpace.md) {
            // Health indicator
            ZStack {
                Circle()
                    .fill(conn.health.color.opacity(0.15))
                    .frame(width: 28, height: 28)
                Circle()
                    .fill(conn.health.color)
                    .frame(width: 8, height: 8)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(conn.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TextGrade.primary)
                    Text(conn.health.title)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(conn.health.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(conn.health.color.opacity(0.1)))
                    if conn.id == store.state.activeConnectorID {
                        Text("默认")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Brand.primary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Brand.primaryMuted))
                    }
                }

                Text("\(conn.modelName) · \(conn.endpoint)")
                    .font(.system(size: 10))
                    .foregroundStyle(TextGrade.muted)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(capability.supportsToolCalling ? "工具调用" : "无工具")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(capability.supportsToolCalling ? Semantic.success : TextGrade.ghost)
                    Text("·")
                        .foregroundStyle(TextGrade.ghost)
                    Text(capability.toolCallingSourceDetail)
                        .font(.system(size: 8))
                        .foregroundStyle(TextGrade.ghost)
                    if let learned = capability.learnedToolCallingDetail {
                        Text("·")
                            .foregroundStyle(TextGrade.ghost)
                        Text(learned)
                            .font(.system(size: 8))
                            .foregroundStyle(TextGrade.ghost)
                    }
                }
            }

            Spacer()

            HStack(spacing: 4) {
                IconButton(icon: "arrow.clockwise", tooltip: "健康检查") {
                    store.checkConnectorHealth(id: conn.id)
                }

                if conn.toolCallingCapability != nil {
                    IconButton(icon: "arrow.counterclockwise.circle", tooltip: "清除已学习兼容性") {
                        store.clearLearnedToolCallingCapability(id: conn.id)
                    }
                }

                IconButton(icon: "pencil", tooltip: "编辑") {
                    onEdit()
                }

                if store.state.connectors.count > 1 || conn.id != store.state.activeConnectorID {
                    IconButton(icon: "trash", tooltip: "删除") {
                        onDelete()
                    }
                }
            }
            .opacity(hovered ? 1 : 0.4)
        }
        .padding(.horizontal, AppSpace.xl)
        .padding(.vertical, AppSpace.md)
        .background(hovered ? SurfaceGrade.hover.opacity(0.4) : Color.clear)
        .onHover { hovered = $0 }
    }
}

// MARK: - Tools Settings

private struct ToolsSettingsTab: View {
    @EnvironmentObject private var store: AppStore
    @State private var serverStatus: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpace.lg) {
                settingsCard(title: "ComfyUI 图片生成") {
                    settingsRow(label: "服务地址") {
                        TextField("http://127.0.0.1:8188", text: Binding(
                            get: { store.state.settings.comfyUIServerURL },
                            set: { store.updateComfyUIServerURL($0) }
                        ))
                        .textFieldStyle(.roundedBorder)

                        Button("测试连接") {
                            Task {
                                let url = store.state.settings.comfyUIServerURL.isEmpty
                                    ? "http://127.0.0.1:8188" : store.state.settings.comfyUIServerURL
                                serverStatus = "连接中…"
                                do {
                                    var request = URLRequest(url: URL(string: "\(url)/system_stats")!)
                                    request.timeoutInterval = 3
                                    let (_, response) = try await URLSession.shared.data(for: request)
                                    if (response as? HTTPURLResponse)?.statusCode == 200 {
                                        serverStatus = "✅ 已连接"
                                    } else {
                                        serverStatus = "❌ 返回异常"
                                    }
                                } catch {
                                    serverStatus = "❌ 无法连接"
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                    }

                    if !serverStatus.isEmpty {
                        Text(serverStatus)
                            .font(AppFont.caption)
                            .foregroundStyle(serverStatus.contains("✅") ? Semantic.success : Semantic.error)
                            .padding(.leading, 80)
                    }

                    settingsRow(label: "模型名称") {
                        TextField("如 sd_xl_base_1.0.safetensors", text: Binding(
                            get: { store.state.settings.comfyUIModelName },
                            set: { store.updateComfyUIModelName($0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }

                    Text("在 ComfyUI 的 models/checkpoints 目录中找到你的模型文件名，填入上方。")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                        .padding(.leading, 80)
                }
            }
            .padding(AppSpace.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Input Settings

// MARK: - Shared Settings Helpers

private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: AppSpace.md) {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(TextGrade.ghost)
            .textCase(.uppercase)
        content()
    }
    .padding(AppSpace.lg)
    .background(
        RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
            .fill(SurfaceGrade.card)
    )
    .overlay(
        RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
            .strokeBorder(SurfaceGrade.border.opacity(0.12), lineWidth: 0.5)
    )
}

private func settingsRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: AppSpace.md) {
        Text(label)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(TextGrade.secondary)
            .frame(width: 72, alignment: .leading)
        content()
    }
}

private struct InputSettingsTab: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpace.lg) {
                settingsCard(title: "上下文") {
                    settingsRow(label: "模式") {
                        Picker("", selection: Binding(
                            get: { store.state.settings.contextMode },
                            set: { store.updateContextMode($0) }
                        )) {
                            ForEach(ContextMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    Text(store.state.settings.contextMode.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(TextGrade.muted)
                        .padding(.leading, 80)
                }

                settingsCard(title: "界面") {
                    settingsRow(label: "输入框") {
                        Toggle("紧凑模式", isOn: Binding(
                            get: { store.state.settings.compactComposer },
                            set: { store.toggleCompactComposer($0) }
                        ))
                        .font(.system(size: 12))
                        .toggleStyle(.switch)
                    }

                    settingsRow(label: "调试") {
                        Toggle("显示日志细节", isOn: Binding(
                            get: { store.state.settings.showDebugPanels },
                            set: { store.toggleDebugPanels($0) }
                        ))
                        .font(.system(size: 12))
                        .toggleStyle(.switch)
                    }
                }
            }
            .padding(AppSpace.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Gateway Settings

private struct GatewaySettingsTab: View {
    @ObservedObject private var gateway = MessagingGateway.shared
    @State private var showingAddChannel = false
    @State private var editingChannel: ChannelConfig?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpace.lg) {
                // Status
                settingsCard(title: "网关状态") {
                    HStack(spacing: AppSpace.sm) {
                        Circle()
                            .fill(gateway.isRunning ? Semantic.success : TextGrade.ghost)
                            .frame(width: 8, height: 8)
                        Text(gateway.isRunning ? "运行中" : "未启动")
                            .font(AppFont.caption)
                            .foregroundStyle(TextGrade.secondary)
                        Spacer()
                        Text("端口 18789")
                            .font(AppFont.tiny)
                            .foregroundStyle(TextGrade.ghost)
                    }
                }

                // Channels
                settingsCard(title: "消息通道") {
                    if gateway.channels.isEmpty {
                        Text("暂无消息通道，点击下方按钮添加飞书、Telegram 等平台的机器人接入。")
                            .font(AppFont.caption)
                            .foregroundStyle(TextGrade.muted)
                            .padding(.vertical, AppSpace.sm)
                    } else {
                        VStack(spacing: AppSpace.sm) {
                            ForEach(gateway.channels, id: \.id) { config in
                                channelRow(config)
                            }
                        }
                    }

                    Button {
                        showingAddChannel = true
                    } label: {
                        HStack(spacing: AppSpace.xs) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 12))
                            Text("添加通道")
                                .font(AppFont.caption)
                        }
                        .foregroundStyle(Brand.primary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, AppSpace.sm)
                }
            }
            .padding(AppSpace.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showingAddChannel) {
            ChannelEditSheet(channel: nil)
        }
        .sheet(item: $editingChannel) { config in
            ChannelEditSheet(channel: config)
        }
    }

    private func channelRow(_ config: ChannelConfig) -> some View {
        HStack(spacing: AppSpace.md) {
            Image(systemName: config.type.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(gateway.connectedChannels.contains(config.id) ? Semantic.success : TextGrade.ghost)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                    .font(AppFont.caption.bold())
                    .foregroundStyle(TextGrade.primary)
                Text(config.type.displayName)
                    .font(AppFont.tiny)
                    .foregroundStyle(TextGrade.muted)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { config.enabled },
                set: { _ in gateway.toggleChannel(id: config.id) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            Button {
                editingChannel = config
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 11))
                    .foregroundStyle(TextGrade.muted)
            }
            .buttonStyle(.plain)

            Button {
                gateway.removeChannel(id: config.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(Semantic.error)
            }
            .buttonStyle(.plain)
        }
        .padding(AppSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(SurfaceGrade.elevated)
        )
    }
}

// MARK: - Channel Edit Sheet

private struct ChannelEditSheet: View {
    @ObservedObject private var gateway = MessagingGateway.shared
    @Environment(\.dismiss) private var dismiss
    let channel: ChannelConfig?

    @State private var selectedType: ChannelType = .feishu
    @State private var name: String = ""
    @State private var appID: String = ""
    @State private var appSecret: String = ""
    @State private var verificationToken: String = ""
    @State private var encryptKey: String = ""
    @State private var botToken: String = ""
    @State private var corpID: String = ""
    @State private var corpSecret: String = ""
    @State private var agentID: String = ""
    @State private var webhookURL: String = ""
    @State private var allowedSenders: String = ""

    init(channel: ChannelConfig?) {
        self.channel = channel
        if let ch = channel {
            _selectedType = State(initialValue: ch.type)
            _name = State(initialValue: ch.name)
            _appID = State(initialValue: ch.config["app_id"] ?? "")
            _appSecret = State(initialValue: ch.config["app_secret"] ?? "")
            _verificationToken = State(initialValue: ch.config["verification_token"] ?? "")
            _encryptKey = State(initialValue: ch.config["encrypt_key"] ?? "")
            _botToken = State(initialValue: ch.config["bot_token"] ?? "")
            _corpID = State(initialValue: ch.config["corp_id"] ?? "")
            _corpSecret = State(initialValue: ch.config["corp_secret"] ?? "")
            _agentID = State(initialValue: ch.config["agent_id"] ?? "")
            _webhookURL = State(initialValue: ch.config["webhook_url"] ?? "")
            _allowedSenders = State(initialValue: ch.allowedSenders.joined(separator: ", "))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(channel == nil ? "添加消息通道" : "编辑消息通道")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(TextGrade.primary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(TextGrade.muted)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(SurfaceGrade.elevated))
                }
                .buttonStyle(.plain)
            }
            .padding(AppSpace.lg)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpace.lg) {
                    // Type picker (only for new)
                    if channel == nil {
                        VStack(alignment: .leading, spacing: AppSpace.xs) {
                            Text("平台").font(AppFont.caption.bold()).foregroundStyle(TextGrade.secondary)
                            HStack(spacing: AppSpace.sm) {
                                ForEach(ChannelType.allCases, id: \.rawValue) { type in
                                    Button {
                                        selectedType = type
                                        if name.isEmpty || ChannelType.allCases.map({ $0.displayName }).contains(name) {
                                            name = type.displayName
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: type.icon)
                                                .font(.system(size: 10))
                                            Text(type.displayName)
                                                .font(AppFont.tiny)
                                        }
                                        .padding(.horizontal, AppSpace.sm)
                                        .padding(.vertical, 5)
                                        .background(
                                            Capsule().fill(selectedType == type ? Brand.primary.opacity(0.15) : SurfaceGrade.elevated)
                                        )
                                        .foregroundStyle(selectedType == type ? Brand.primary : TextGrade.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    // Name
                    VStack(alignment: .leading, spacing: AppSpace.xs) {
                        Text("名称").font(AppFont.caption.bold()).foregroundStyle(TextGrade.secondary)
                        TextField("通道名称", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .font(AppFont.caption)
                    }

                    // Type-specific fields
                    switch selectedType {
                    case .feishu:
                        configField("App ID", text: $appID, placeholder: "cli_xxxxx")
                        configField("App Secret", text: $appSecret, placeholder: "飞书开放平台 App Secret", isSecure: true)
                        configField("Verification Token", text: $verificationToken, placeholder: "事件订阅验证令牌")
                        configField("Encrypt Key", text: $encryptKey, placeholder: "事件加密密钥（可选）")

                    case .telegram:
                        configField("Bot Token", text: $botToken, placeholder: "从 @BotFather 获取", isSecure: true)

                    case .wecom:
                        configField("Corp ID", text: $corpID, placeholder: "企业微信企业 ID")
                        configField("Corp Secret", text: $corpSecret, placeholder: "应用的 Secret", isSecure: true)
                        configField("Agent ID", text: $agentID, placeholder: "应用 AgentId")

                    case .slack:
                        configField("Bot Token", text: $botToken, placeholder: "xoxb-xxxxx", isSecure: true)
                        configField("App Token", text: $appSecret, placeholder: "xapp-xxxxx (Socket Mode)", isSecure: true)

                    case .webhook:
                        configField("Webhook URL", text: $webhookURL, placeholder: "用于发送回复的外部 URL")
                    }

                    // Allowed senders
                    VStack(alignment: .leading, spacing: AppSpace.xs) {
                        Text("允许的发送者").font(AppFont.caption.bold()).foregroundStyle(TextGrade.secondary)
                        TextField("逗号分隔的用户 ID（留空=所有人）", text: $allowedSenders)
                            .textFieldStyle(.roundedBorder)
                            .font(AppFont.caption)
                        Text("限制哪些用户可以通过此通道向来财发送消息")
                            .font(AppFont.tiny)
                            .foregroundStyle(TextGrade.ghost)
                    }
                }
                .padding(AppSpace.lg)
            }

            Divider()

            // Actions
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(TextGrade.secondary)

                Button(channel == nil ? "添加" : "保存") {
                    save()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.primary)
            }
            .padding(AppSpace.lg)
        }
        .frame(width: 480, height: 520)
        .background(SurfaceGrade.base)
    }

    private func configField(_ label: String, text: Binding<String>, placeholder: String, isSecure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: AppSpace.xs) {
            Text(label).font(AppFont.caption.bold()).foregroundStyle(TextGrade.secondary)
            if isSecure {
                SecureField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(AppFont.caption)
            } else {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(AppFont.caption)
            }
        }
    }

    private func save() {
        var config: [String: String] = [:]
        switch selectedType {
        case .feishu:
            config["app_id"] = appID
            config["app_secret"] = appSecret
            if !verificationToken.isEmpty { config["verification_token"] = verificationToken }
            if !encryptKey.isEmpty { config["encrypt_key"] = encryptKey }
        case .telegram:
            config["bot_token"] = botToken
        case .wecom:
            config["corp_id"] = corpID
            config["corp_secret"] = corpSecret
            config["agent_id"] = agentID
        case .slack:
            config["bot_token"] = botToken
            config["app_token"] = appSecret
        case .webhook:
            config["webhook_url"] = webhookURL
        }

        let senders = allowedSenders
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let existing = channel {
            // Update existing channel
            gateway.removeChannel(id: existing.id)
            let updated = ChannelConfig(
                id: existing.id,
                type: selectedType,
                name: name.isEmpty ? selectedType.displayName : name,
                enabled: existing.enabled,
                config: config,
                allowedSenders: senders
            )
            gateway.addChannel(updated)
        } else {
            // Add new channel
            let newChannel = ChannelConfig(
                type: selectedType,
                name: name.isEmpty ? selectedType.displayName : name,
                config: config,
                allowedSenders: senders
            )
            gateway.addChannel(newChannel)
        }
    }
}

// MARK: - Advanced Settings

private struct AdvancedSettingsTab: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpace.lg) {
                TeleportPanel()
                ModelRegressionPanel()
            }
            .padding(AppSpace.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
