import LaicaiNativeDomain
import LaicaiNativeFoundation
import SwiftUI

var appVersionLabel: String {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    return "v\(version) · build \(build)"
}

private var geminiBridgeDescription: String {
    let domains = GeminiOAuthBridgeManager.domains.joined(separator: "、")
    let socksAddress = "\(GeminiOAuthBridgeManager.socksHost):\(GeminiOAuthBridgeManager.socksPort)"
    return "用于 Gemini 与 Antigravity 不吃系统代理时，临时把 \(domains) " + "转发到 Veee SOCKS \(socksAddress)。"
}

private var geminiBridgePrivacyNote: String {
    "启动会弹出 macOS 管理员授权，授权后桥在后台运行；失败会自动回滚 hosts。" + "来财不会读取、保存或代理你的 Mac 密码。"
}

private var feishuWebSocketHint: String {
    "飞书使用 WebSocket 长连接，无需公网 IP。请在飞书开放平台 > 事件与回调 > " + "回调配置中选择「使用长连接接收事件」。"
}

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
                        HStack(spacing: AppSpace.small) {
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
                        .padding(.horizontal, AppSpace.small)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                                .fill(isActive ? SurfaceGrade.hover : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.vertical, AppSpace.large)
            .padding(.horizontal, AppSpace.small)
            .frame(width: 136)
            .background(SurfaceGrade.panel)

            Rectangle().fill(SurfaceGrade.divider).frame(width: 1)

            // Content
            VStack(spacing: 0) {
                // Header
                HStack(spacing: AppSpace.medium) {
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
                .padding(.horizontal, AppSpace.extraLarge)
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

// MARK: - Connectors Settings

private struct ConnectorsSettingsTab: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingAddSheet = false
    @State private var editingConnectorID: UUID?
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
            .padding(.horizontal, AppSpace.extraLarge)
            .padding(.vertical, AppSpace.medium)

            Divider()

            if store.state.connectors.isEmpty {
                Spacer()
                VStack(spacing: AppSpace.medium) {
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
                            .padding(.horizontal, AppSpace.large)
                            .padding(.vertical, AppSpace.small)
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
                                onEdit: { editingConnectorID = conn.id },
                                onDelete: { deletingConnector = conn }
                            )
                            .onTapGesture { editingConnectorID = conn.id }
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
        .sheet(
            isPresented: Binding(
                get: { editingConnectorID != nil },
                set: { if !$0 { editingConnectorID = nil } }
            )
        ) {
            if let connID = editingConnectorID,
                let conn = store.state.connectors.first(where: { $0.id == connID })
            {
                ConnectorEditSheet(mode: .edit(conn)) { updated in
                    store.updateConnector(updated)
                    ToastCenter.shared.success("已更新 \(updated.name)")
                } onSaveAndTest: { updated in
                    store.updateConnector(updated)
                    store.checkConnectorHealth(id: updated.id)
                    ToastCenter.shared.show("正在测试 \(updated.name)")
                }
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
}

private struct ConnectorSettingsRow: View {
    let conn: ConnectorProfile
    let onEdit: () -> Void
    let onDelete: () -> Void
    @EnvironmentObject private var store: AppStore
    @State private var hovered = false

    var body: some View {
        let capability = ConnectorCapabilityProfile.infer(for: conn, mode: store.state.settings.contextMode)
        HStack(spacing: AppSpace.medium) {
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
        .padding(.horizontal, AppSpace.extraLarge)
        .padding(.vertical, AppSpace.medium)
        .background(hovered ? SurfaceGrade.hover.opacity(0.4) : Color.clear)
        .onHover { hovered = $0 }
    }
}

// MARK: - Tools Settings

private struct ToolsSettingsTab: View {
    @EnvironmentObject private var store: AppStore
    @State private var serverStatus: String = ""
    @State private var bridgeStatus: GeminiOAuthBridgeStatus = .empty

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpace.large) {
                geminiBridgeCard

                settingsCard(title: "ComfyUI 图片生成") {
                    settingsRow(label: "服务地址") {
                        TextField(
                            "http://127.0.0.1:8188",
                            text: Binding(
                                get: { store.state.settings.comfyUIServerURL },
                                set: { store.updateComfyUIServerURL($0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)

                        Button("测试连接") {
                            Task {
                                let url =
                                    store.state.settings.comfyUIServerURL.isEmpty
                                    ? "http://127.0.0.1:8188" : store.state.settings.comfyUIServerURL
                                serverStatus = "连接中…"
                                do {
                                    guard let statsURL = URL(string: "\(url)/system_stats") else {
                                        serverStatus = "❌ URL 无效"
                                        return
                                    }
                                    var request = URLRequest(url: statsURL)
                                    request.timeoutInterval = NetworkDefaults.quickProbe
                                    let (_, response) = try await NetworkDefaults.ephemeralSession.data(for: request)
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
                        TextField(
                            "如 sd_xl_base_1.0.safetensors",
                            text: Binding(
                                get: { store.state.settings.comfyUIModelName },
                                set: { store.updateComfyUIModelName($0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                    }

                    Text("在 ComfyUI 的 models/checkpoints 目录中找到你的模型文件名，填入上方。")
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                        .padding(.leading, 80)
                }
            }
            .padding(AppSpace.extraLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { refreshBridgeStatus() }
    }

    private var geminiBridgeCard: some View {
        settingsCard(title: "Gemini / Antigravity 桥") {
            VStack(alignment: .leading, spacing: AppSpace.medium) {
                HStack(alignment: .center, spacing: AppSpace.medium) {
                    ZStack {
                        Circle()
                            .fill(bridgeTone.opacity(0.14))
                            .frame(width: 26, height: 26)
                        Image(systemName: bridgeIcon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(bridgeTone)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(bridgeStatus.title)
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(TextGrade.primary)
                        Text(bridgeStatus.detail)
                            .font(AppFont.caption)
                            .foregroundStyle(TextGrade.muted)
                            .lineLimit(2)
                    }

                    Spacer()

                    Button("刷新") {
                        refreshBridgeStatus()
                    }
                    .buttonStyle(.bordered)

                    Button(bridgePrimaryActionTitle) {
                        store.startGeminiOAuthBridge()
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            refreshBridgeStatus()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(bridgeStatus.socksAvailable ? Brand.primary : Semantic.warning)

                    if bridgeStatus.hasPartialState {
                        Button("清理") {
                            store.stopGeminiOAuthBridge()
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(2))
                                refreshBridgeStatus()
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(Semantic.error)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
                    Text(geminiBridgeDescription)
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(geminiBridgePrivacyNote)
                        .font(AppFont.caption)
                        .foregroundStyle(TextGrade.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: AppSpace.small) {
                    Button("打开脚本位置") {
                        GeminiOAuthBridgeManager.shared.revealHelperInFinder()
                    }
                    .buttonStyle(.bordered)

                    Text(bridgeStatus.scriptPath.isEmpty ? GeminiOAuthBridgeManager.shared.scriptURL.path : bridgeStatus.scriptPath)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(TextGrade.ghost)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let processLine = bridgeStatus.processLine {
                    Text(processLine)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(TextGrade.ghost)
                        .lineLimit(2)
                }
            }
        }
    }

    private var bridgeTone: Color {
        if bridgeStatus.isRunning { return Semantic.success }
        if bridgeStatus.hasPartialState || !bridgeStatus.socksAvailable { return Semantic.warning }
        return TextGrade.ghost
    }

    private var bridgeIcon: String {
        if bridgeStatus.isRunning { return "checkmark.shield" }
        if bridgeStatus.hasPartialState { return "wrench.and.screwdriver" }
        return "link.badge.plus"
    }

    private var bridgePrimaryActionTitle: String {
        if bridgeStatus.isRunning { return "重启修复" }
        if bridgeStatus.hasPartialState { return "修复启动" }
        return "启动"
    }

    private func refreshBridgeStatus() {
        bridgeStatus = GeminiOAuthBridgeManager.shared.status()
    }
}

// MARK: - Input Settings

// MARK: - Shared Settings Helpers

func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: AppSpace.medium) {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(TextGrade.ghost)
            .textCase(.uppercase)
        content()
    }
    .padding(AppSpace.large)
    .background(
        RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
            .fill(SurfaceGrade.card)
    )
    .overlay(
        RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
            .strokeBorder(SurfaceGrade.border.opacity(0.12), lineWidth: 0.5)
    )
}

func settingsRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: AppSpace.medium) {
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
            VStack(alignment: .leading, spacing: AppSpace.large) {
                settingsCard(title: "上下文") {
                    settingsRow(label: "模式") {
                        Picker(
                            "",
                            selection: Binding(
                                get: { store.state.settings.contextMode },
                                set: { store.updateContextMode($0) }
                            )
                        ) {
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
                        Toggle(
                            "紧凑模式",
                            isOn: Binding(
                                get: { store.state.settings.compactComposer },
                                set: { store.toggleCompactComposer($0) }
                            )
                        )
                        .font(.system(size: 12))
                        .toggleStyle(.switch)
                    }

                    settingsRow(label: "调试") {
                        Toggle(
                            "显示日志细节",
                            isOn: Binding(
                                get: { store.state.settings.showDebugPanels },
                                set: { store.toggleDebugPanels($0) }
                            )
                        )
                        .font(.system(size: 12))
                        .toggleStyle(.switch)
                    }

                }
            }
            .padding(AppSpace.extraLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Gateway Settings

private struct GatewaySettingsTab: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var gateway = MessagingGateway.shared
    @State private var showingAddChannel = false
    @State private var editingChannel: ChannelConfig?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpace.large) {
                // Status
                settingsCard(title: "网关状态") {
                    VStack(alignment: .leading, spacing: AppSpace.small) {
                        HStack(spacing: AppSpace.small) {
                            Image(systemName: gateway.isRunning ? "checkmark.circle.fill" : "stop.circle")
                                .foregroundStyle(gateway.isRunning ? Semantic.success : TextGrade.ghost)
                            Text(gateway.isRunning ? "运行中" : "未启动")
                                .font(AppFont.caption)
                                .foregroundStyle(TextGrade.secondary)
                            Spacer()
                            Text("端口 18789")
                                .font(AppFont.tiny)
                                .foregroundStyle(TextGrade.ghost)

                            Button(gateway.isRunning ? "停止" : "启动") {
                                if gateway.isRunning {
                                    gateway.stop()
                                } else {
                                    store.startGateway()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(gateway.isRunning ? Semantic.error : Semantic.success)
                            .controlSize(.small)
                            .accessibilityLabel(gateway.isRunning ? "停止消息网关" : "启动消息网关")
                        }
                        if let error = gateway.gatewayError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(AppFont.tiny)
                                .foregroundStyle(Semantic.error)
                                .accessibilityLabel("消息网关错误：\(error)")
                        }
                    }
                }

                // Channels
                settingsCard(title: "消息通道") {
                    if gateway.channels.isEmpty {
                        Text("暂无消息通道，点击下方按钮添加飞书、Telegram 等平台接入。")
                            .font(AppFont.caption)
                            .foregroundStyle(TextGrade.muted)
                            .padding(.vertical, AppSpace.small)
                    } else {
                        VStack(spacing: AppSpace.small) {
                            ForEach(gateway.channels, id: \.id) { config in
                                channelRow(config)
                            }
                        }
                    }

                    Button {
                        showingAddChannel = true
                    } label: {
                        HStack(spacing: AppSpace.extraSmall) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 12))
                            Text("添加通道")
                                .font(AppFont.caption)
                        }
                        .foregroundStyle(Brand.primary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, AppSpace.small)
                }
            }
            .padding(AppSpace.extraLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showingAddChannel) {
            ChannelEditSheet(channel: nil)
        }
        .sheet(item: $editingChannel) { config in
            ChannelEditSheet(channel: config)
        }
        .onAppear {
            _ = gateway.prepare(workspaceRoot: store.state.settings.workspacePath)
        }
    }

    private func channelRow(_ config: ChannelConfig) -> some View {
        let status = channelStatus(config)
        return HStack(spacing: AppSpace.medium) {
            Image(systemName: config.type.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(channelStatusColor(status))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                    .font(AppFont.caption.bold())
                    .foregroundStyle(TextGrade.primary)
                Text("\(config.type.displayName) · \(status.title)")
                    .font(AppFont.tiny)
                    .foregroundStyle(channelStatusColor(status))
                if let detail = status.detail {
                    Text(detail)
                        .font(AppFont.tiny)
                        .foregroundStyle(TextGrade.muted)
                        .lineLimit(2)
                }
            }

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { config.enabled },
                    set: { _ in gateway.toggleChannel(id: config.id) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!config.type.isAvailable)
            .accessibilityLabel("\(config.name)通道")
            .accessibilityValue(status.title)

            Button {
                editingChannel = config
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 11))
                    .foregroundStyle(TextGrade.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑\(config.name)")

            Button {
                gateway.removeChannel(id: config.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(Semantic.error)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除\(config.name)")
        }
        .padding(AppSpace.small)
        .opacity(config.type.isAvailable ? 1 : 0.62)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(SurfaceGrade.elevated)
        )
    }

    private func channelStatus(_ config: ChannelConfig) -> ChannelConnectionState {
        if !config.type.isAvailable {
            return .unavailable(config.type.availabilityDescription)
        }
        if !config.enabled { return .disabled }
        return gateway.connectionStates[config.id] ?? (gateway.isRunning ? .connecting : .disabled)
    }

    private func channelStatusColor(_ status: ChannelConnectionState) -> Color {
        switch status {
        case .connected: return Semantic.success
        case .connecting: return Semantic.warning
        case .failed: return Semantic.error
        case .disabled, .unavailable: return TextGrade.muted
        }
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
    @State private var saveError: String?

    init(channel: ChannelConfig?) {
        self.channel = channel
        if let channel {
            _selectedType = State(initialValue: channel.type)
            _name = State(initialValue: channel.name)
            _appID = State(initialValue: channel.config["app_id"] ?? "")
            _appSecret = State(initialValue: channel.config["app_secret"] ?? "")
            _verificationToken = State(initialValue: channel.config["verification_token"] ?? "")
            _encryptKey = State(initialValue: channel.config["encrypt_key"] ?? "")
            _botToken = State(initialValue: channel.config["bot_token"] ?? "")
            _corpID = State(initialValue: channel.config["corp_id"] ?? "")
            _corpSecret = State(initialValue: channel.config["corp_secret"] ?? "")
            _agentID = State(initialValue: channel.config["agent_id"] ?? "")
            _webhookURL = State(initialValue: channel.config["webhook_url"] ?? "")
            _allowedSenders = State(initialValue: channel.allowedSenders.joined(separator: ", "))
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
            }
            .padding(AppSpace.large)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpace.large) {
                    // Type picker (only for new)
                    if channel == nil {
                        VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
                            Text("平台").font(AppFont.caption.bold()).foregroundStyle(TextGrade.secondary)
                            HStack(spacing: AppSpace.small) {
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
                                            if !type.isAvailable {
                                                Text("未实现")
                                                    .font(.system(size: 8, weight: .semibold))
                                            }
                                        }
                                        .padding(.horizontal, AppSpace.small)
                                        .padding(.vertical, 5)
                                        .background(
                                            Capsule().fill(selectedType == type ? Brand.primary.opacity(0.15) : SurfaceGrade.elevated)
                                        )
                                        .foregroundStyle(selectedType == type ? Brand.primary : TextGrade.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!type.isAvailable)
                                    .opacity(type.isAvailable ? 1 : 0.5)
                                    .accessibilityLabel("\(type.displayName)，\(type.availabilityDescription)")
                                }
                            }
                            Text(selectedType.availabilityDescription)
                                .font(AppFont.tiny)
                                .foregroundStyle(selectedType.isAvailable ? TextGrade.muted : Semantic.warning)
                        }
                    }

                    // Name
                    VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
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
                        Text(feishuWebSocketHint)
                            .font(AppFont.tiny)
                            .foregroundStyle(TextGrade.ghost)

                    case .telegram:
                        configField("Bot Token", text: $botToken, placeholder: "从 @BotFather 获取", isSecure: true)

                    case .wecom:
                        configField("Corp ID", text: $corpID, placeholder: "企业微信企业 ID")
                        configField("Corp Secret", text: $corpSecret, placeholder: "应用的 Secret", isSecure: true)
                        configField("应用 ID", text: $agentID, placeholder: "企业微信 AgentId")

                    case .slack:
                        configField("Bot Token", text: $botToken, placeholder: "xoxb-xxxxx", isSecure: true)
                        configField("App Token", text: $appSecret, placeholder: "xapp-xxxxx (Socket Mode)", isSecure: true)

                    case .webhook:
                        VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
                            Text("接收地址").font(AppFont.caption.bold()).foregroundStyle(TextGrade.secondary)
                            Text("POST http://127.0.0.1:18789/webhook")
                                .font(AppFont.tiny.monospaced())
                                .foregroundStyle(TextGrade.secondary)
                            Text("Webhook 当前仅接收入站消息；JSON 需包含非空 text 或 message。")
                                .font(AppFont.tiny)
                                .foregroundStyle(TextGrade.muted)
                        }
                    }

                    // Allowed senders
                    VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
                        Text("允许的发送者").font(AppFont.caption.bold()).foregroundStyle(TextGrade.secondary)
                        TextField("逗号分隔的用户 ID（留空=所有人）", text: $allowedSenders)
                            .textFieldStyle(.roundedBorder)
                            .font(AppFont.caption)
                        Text("限制哪些用户可以通过此通道向来财发送消息")
                            .font(AppFont.tiny)
                            .foregroundStyle(TextGrade.ghost)
                    }
                }
                .padding(AppSpace.large)
            }

            Divider()

            // Actions
            HStack {
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(AppFont.tiny)
                        .foregroundStyle(Semantic.error)
                        .accessibilityLabel("保存失败：\(saveError)")
                }
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(TextGrade.secondary)

                Button(channel == nil ? "添加" : "保存") {
                    if save() { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.primary)
                .disabled(!selectedType.isAvailable || !hasRequiredConfiguration)
                .accessibilityHint("保存后会立即验证并连接已启用的通道")
            }
            .padding(AppSpace.large)
        }
        .frame(width: 480, height: 520)
        .background(SurfaceGrade.base)
    }

    private func configField(_ label: String, text: Binding<String>, placeholder: String, isSecure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: AppSpace.extraSmall) {
            Text(label).font(AppFont.caption.bold()).foregroundStyle(TextGrade.secondary)
            if isSecure {
                SecureField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(AppFont.caption)
                    .accessibilityLabel(label)
            } else {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(AppFont.caption)
                    .accessibilityLabel(label)
            }
        }
    }

    private var hasRequiredConfiguration: Bool {
        switch selectedType {
        case .feishu:
            return !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !appSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .telegram: return !botToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .webhook: return true
        case .wecom, .slack: return false
        }
    }

    @discardableResult
    private func save() -> Bool {
        guard selectedType.isAvailable else {
            saveError = selectedType.availabilityDescription
            return false
        }
        guard hasRequiredConfiguration else {
            saveError = "请填写当前平台的必填配置。"
            return false
        }

        let config = channelConfigFields()
        let senders =
            allowedSenders
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard persistChannel(config: config, allowedSenders: senders) else {
            return false
        }
        saveError = nil
        return true
    }

    private func channelConfigFields() -> [String: String] {
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
        return config
    }

    private func persistChannel(config: [String: String], allowedSenders: [String]) -> Bool {
        if let existing = channel {
            let updated = ChannelConfig(
                id: existing.id,
                type: selectedType,
                name: name.isEmpty ? selectedType.displayName : name,
                enabled: existing.enabled,
                config: config,
                allowedSenders: allowedSenders
            )
            guard gateway.updateChannel(updated) else {
                saveError = gateway.gatewayError ?? "通道保存失败"
                return false
            }
        } else {
            let newChannel = ChannelConfig(
                type: selectedType,
                name: name.isEmpty ? selectedType.displayName : name,
                config: config,
                allowedSenders: allowedSenders
            )
            guard gateway.addChannel(newChannel) else {
                saveError = gateway.gatewayError ?? "通道保存失败"
                return false
            }
        }
        return true
    }
}

// MARK: - Advanced Settings

private struct AdvancedSettingsTab: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpace.large) {
                TeleportPanel()
                ModelRegressionPanel()
            }
            .padding(AppSpace.extraLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
