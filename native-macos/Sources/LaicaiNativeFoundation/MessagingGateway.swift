import Foundation
import LaicaiNativeDomain

// MARK: - Messaging Channel Protocol

/// A messaging channel that can receive and send messages from external platforms.
public protocol MessagingChannel: AnyObject, Sendable {
    var channelType: ChannelType { get }
    var isConnected: Bool { get }
    func connect() async throws
    func disconnect() async
    func sendMessage(_ text: String, to recipient: String) async throws
    var onMessageReceived: (@Sendable (IncomingMessage) -> Void)? { get set }
    var onConnectionStateChanged: (@Sendable (Bool, String?) -> Void)? { get set }
}

public enum ChannelCapability: String, Codable, Sendable {
    case bidirectional
    case inboundWebhook
    case unavailable
}

public enum ChannelType: String, Codable, Sendable, CaseIterable {
    case telegram
    case feishu
    case wecom
    case slack
    case webhook

    public var displayName: String {
        switch self {
        case .telegram: return "Telegram"
        case .feishu: return "飞书"
        case .wecom: return "企业微信"
        case .slack: return "Slack"
        case .webhook: return "Webhook"
        }
    }

    public var icon: String {
        switch self {
        case .telegram: return "paperplane.fill"
        case .feishu: return "bird.fill"
        case .wecom: return "message.fill"
        case .slack: return "number"
        case .webhook: return "antenna.radiowaves.left.and.right"
        }
    }

    public var capability: ChannelCapability {
        switch self {
        case .telegram, .feishu: return .bidirectional
        case .webhook: return .inboundWebhook
        case .wecom, .slack: return .unavailable
        }
    }

    public var isAvailable: Bool { capability != .unavailable }

    public var availabilityDescription: String {
        switch self {
        case .telegram: return "双向消息（轮询）"
        case .feishu: return "双向消息（WebSocket）"
        case .webhook: return "仅接收入站消息"
        case .wecom: return "尚未实现入站消息接收"
        case .slack: return "尚未实现入站消息接收"
        }
    }
}

public enum ChannelConnectionState: Equatable, Sendable {
    case disabled
    case connecting
    case connected
    case unavailable(String)
    case failed(String)

    public var title: String {
        switch self {
        case .disabled: return "已停用"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .unavailable: return "未实现"
        case .failed: return "连接失败"
        }
    }

    public var detail: String? {
        switch self {
        case .unavailable(let detail), .failed(let detail): return detail
        case .disabled, .connecting, .connected: return nil
        }
    }
}

// MARK: - Incoming Message

public struct IncomingMessage: Sendable {
    public let id: String
    public let channel: ChannelType
    public let sender: String
    public let senderName: String
    public let text: String
    public let timestamp: Date
    public let replyTo: String?
    public let metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        channel: ChannelType,
        sender: String,
        senderName: String = "",
        text: String,
        timestamp: Date = Date(),
        replyTo: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.channel = channel
        self.sender = sender
        self.senderName = senderName
        self.text = text
        self.timestamp = timestamp
        self.replyTo = replyTo
        self.metadata = metadata
    }
}

// MARK: - Channel Configuration

public struct ChannelConfig: Codable, Sendable, Identifiable {
    public var id: UUID
    public var type: ChannelType
    public var name: String
    public var enabled: Bool
    public var config: [String: String]
    public var allowedSenders: [String]

    public init(
        id: UUID = UUID(),
        type: ChannelType,
        name: String = "",
        enabled: Bool = true,
        config: [String: String] = [:],
        allowedSenders: [String] = []
    ) {
        self.id = id
        self.type = type
        self.name = name.isEmpty ? type.displayName : name
        self.enabled = enabled
        self.config = config
        self.allowedSenders = allowedSenders
    }
}

// MARK: - Messaging Gateway

@MainActor
public final class MessagingGateway: ObservableObject {
    public static let shared = MessagingGateway()

    @Published public private(set) var channels: [ChannelConfig] = []
    @Published public private(set) var connectedChannels: Set<UUID> = []
    @Published public private(set) var connectionStates: [UUID: ChannelConnectionState] = [:]
    @Published public private(set) var messageLog: [IncomingMessage] = []
    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var gatewayError: String?

    /// Callback to process an incoming message through the agent
    public var onProcessMessage: ((IncomingMessage) async -> String)?

    private var activeChannels: [UUID: any MessagingChannel] = [:]
    private var httpServer: GatewayHTTPServer?
    private var persistPath: String = ""

    init() {}

    // MARK: - Lifecycle

    @discardableResult
    public func prepare(workspaceRoot: String) -> Bool {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let dir =
            root.isEmpty
            ? LaicaiStoragePaths.appDirectory.path
            : (root as NSString).appendingPathComponent(".laicai")
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            gatewayError = "无法创建消息网关目录：\(error.localizedDescription)"
            return false
        }
        let nextPersistPath = (dir as NSString).appendingPathComponent("messaging_channels.json")
        if persistPath != nextPersistPath {
            persistPath = nextPersistPath
            loadChannels()
        }
        return true
    }

    @discardableResult
    public func start(workspaceRoot: String, port: Int = 18789) -> Bool {
        if isRunning { return true }
        gatewayError = nil
        guard prepare(workspaceRoot: workspaceRoot) else { return false }

        // Start HTTP webhook server
        httpServer = GatewayHTTPServer(port: port) { [weak self] message in
            await self?.handleIncomingMessage(message)
        }
        switch httpServer?.start() {
        case .success:
            break
        case .failure(let error):
            gatewayError = error.localizedDescription
            httpServer = nil
            isRunning = false
            return false
        case nil:
            gatewayError = "HTTP webhook 服务初始化失败"
            isRunning = false
            return false
        }

        isRunning = true

        // Connect enabled channels
        for channel in channels where channel.enabled {
            Task { await connectChannel(id: channel.id) }
        }
        for channel in channels where !channel.enabled {
            connectionStates[channel.id] = .disabled
        }
        return true
    }

    public func stop() {
        httpServer?.stop()
        for (id, channel) in activeChannels {
            Task { await channel.disconnect() }
            connectedChannels.remove(id)
        }
        activeChannels.removeAll()
        for channel in channels {
            connectionStates[channel.id] = channel.enabled ? .failed("网关已停止") : .disabled
        }
        isRunning = false
    }

    // MARK: - Channel Management

    @discardableResult
    public func addChannel(_ config: ChannelConfig) -> Bool {
        let previous = channels
        channels.append(config)
        guard persist() else {
            channels = previous
            return false
        }
        if config.enabled, isRunning {
            Task { await connectChannel(id: config.id) }
        } else {
            connectionStates[config.id] = .disabled
        }
        return true
    }

    @discardableResult
    public func removeChannel(id: UUID) -> Bool {
        let previous = channels
        channels.removeAll { $0.id == id }
        guard persist() else {
            channels = previous
            return false
        }
        Task {
            await disconnectChannel(id: id)
            connectionStates.removeValue(forKey: id)
        }
        return true
    }

    @discardableResult
    public func updateChannel(_ config: ChannelConfig) -> Bool {
        guard let index = channels.firstIndex(where: { $0.id == config.id }) else {
            return addChannel(config)
        }
        let previous = channels
        channels[index] = config
        guard persist() else {
            channels = previous
            return false
        }
        Task {
            await disconnectChannel(id: config.id)
            if config.enabled, isRunning {
                await connectChannel(id: config.id)
            }
        }
        return true
    }

    @discardableResult
    public func toggleChannel(id: UUID) -> Bool {
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return false }
        guard channels[index].type.isAvailable else {
            connectionStates[id] = .unavailable(channels[index].type.availabilityDescription)
            return false
        }
        let previous = channels[index].enabled
        channels[index].enabled.toggle()
        guard persist() else {
            channels[index].enabled = previous
            return false
        }
        if channels[index].enabled, isRunning {
            Task { await connectChannel(id: id) }
        } else {
            Task { await disconnectChannel(id: id) }
            connectionStates[id] = .disabled
        }
        return true
    }

    /// Expose active channel for webhook routing
    public func activeChannelForID(_ id: UUID) -> (any MessagingChannel)? {
        activeChannels[id]
    }

    // MARK: - Connection

    private func connectChannel(id: UUID) async {
        guard let config = channels.first(where: { $0.id == id }) else { return }
        guard config.type.isAvailable else {
            connectedChannels.remove(id)
            connectionStates[id] = .unavailable(config.type.availabilityDescription)
            return
        }
        connectionStates[id] = .connecting
        let channel: any MessagingChannel

        switch config.type {
        case .telegram:
            channel = TelegramChannel(config: config)
        case .feishu:
            channel = FeishuChannel(config: config)
        case .wecom:
            channel = WeComChannel(config: config)
        case .slack:
            channel = SlackChannel(config: config)
        case .webhook:
            // Webhook is handled by the HTTP server, no persistent connection needed
            connectedChannels.insert(id)
            connectionStates[id] = .connected
            return
        }

        channel.onMessageReceived = { [weak self] message in
            var metadata = message.metadata
            metadata["channelID"] = id.uuidString
            let routedMessage = IncomingMessage(
                id: message.id,
                channel: message.channel,
                sender: message.sender,
                senderName: message.senderName,
                text: message.text,
                timestamp: message.timestamp,
                replyTo: message.replyTo,
                metadata: metadata
            )
            Task { @MainActor [weak self] in
                await self?.handleIncomingMessage(routedMessage)
            }
        }
        channel.onConnectionStateChanged = { [weak self] connected, errorMessage in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if connected {
                    self.connectedChannels.insert(id)
                    self.connectionStates[id] = .connected
                } else {
                    self.connectedChannels.remove(id)
                    self.connectionStates[id] = errorMessage.map(ChannelConnectionState.failed) ?? .disabled
                }
            }
        }

        do {
            try await channel.connect()
            activeChannels[id] = channel
            connectedChannels.insert(id)
            connectionStates[id] = .connected
        } catch {
            activeChannels.removeValue(forKey: id)
            connectedChannels.remove(id)
            connectionStates[id] = .failed(error.localizedDescription)
            LaicaiLog.error("Gateway failed to connect \(config.type.displayName): \(error)")
        }
    }

    private func disconnectChannel(id: UUID) async {
        if let channel = activeChannels.removeValue(forKey: id) {
            await channel.disconnect()
        }
        connectedChannels.remove(id)
        if channels.first(where: { $0.id == id })?.enabled == true {
            connectionStates[id] = .failed("连接已断开")
        } else {
            connectionStates[id] = .disabled
        }
    }

    // MARK: - Message Handling

    private func handleIncomingMessage(_ message: IncomingMessage) async {
        let routedConfig: ChannelConfig? = {
            if let channelID = message.metadata["channelID"],
                let uuid = UUID(uuidString: channelID),
                let config = channels.first(where: { $0.id == uuid })
            {
                return config
            }
            return channels.first(where: { $0.type == message.channel })
        }()

        // Security: check allowed senders
        if let config = routedConfig,
            !config.allowedSenders.isEmpty,
            !config.allowedSenders.contains(message.sender)
        {
            return  // Reject unauthorized sender
        }

        messageLog.append(message)
        if messageLog.count > 200 { messageLog.removeFirst(messageLog.count - 200) }

        // Process through agent
        guard let processor = onProcessMessage else { return }
        let response = await processor(message)

        // Send reply
        if let config = routedConfig,
            let channel = activeChannels[config.id]
        {
            do {
                try await channel.sendMessage(response, to: message.sender)
            } catch {
                connectedChannels.remove(config.id)
                connectionStates[config.id] = .failed("回复发送失败：\(error.localizedDescription)")
                LaicaiLog.error("Gateway reply failed for \(config.type.displayName): \(error)")
            }
        }
    }

    // MARK: - Persistence

    private func loadChannels() {
        guard !persistPath.isEmpty else { return }
        let url = URL(fileURLWithPath: persistPath)
        guard FileManager.default.fileExists(atPath: persistPath) else {
            channels = []
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let loaded = try JSONDecoder().decode([ChannelConfig].self, from: data)
            channels = loaded.map(Self.resolvingSecrets)
        } catch {
            gatewayError = "读取消息通道配置失败：\(error.localizedDescription)"
            channels = []
        }
    }

    @discardableResult
    private func persist() -> Bool {
        guard !persistPath.isEmpty else {
            gatewayError = "消息网关尚未初始化，无法保存通道。"
            return false
        }
        let oldReferences = Self.storedSecretReferences(at: persistPath)
        var stagedReferences: [String] = []
        var persistedChannels = channels
        for channelIndex in persistedChannels.indices {
            for key in Self.secretConfigKeys {
                guard let value = persistedChannels[channelIndex].config[key], !value.isEmpty else { continue }
                let reference = SecretStore.stagedReference(
                    for: "messaging",
                    id: persistedChannels[channelIndex].id,
                    field: key
                )
                guard SecretStore.save(value, reference: reference) else {
                    for staged in stagedReferences { _ = SecretStore.delete(reference: staged) }
                    gatewayError = "无法将 \(persistedChannels[channelIndex].name) 的 \(key) 保存到 Keychain。"
                    return false
                }
                stagedReferences.append(reference)
                persistedChannels[channelIndex].config[key] = reference
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(persistedChannels)
            try data.write(to: URL(fileURLWithPath: persistPath), options: .atomic)
        } catch {
            for staged in stagedReferences { _ = SecretStore.delete(reference: staged) }
            gatewayError = "保存消息通道配置失败：\(error.localizedDescription)"
            return false
        }

        let currentReferences = Set(stagedReferences)
        for reference in oldReferences where !currentReferences.contains(reference) {
            if !SecretStore.delete(reference: reference) {
                LaicaiLog.warning("Unable to delete obsolete messaging Keychain item: \(reference)")
            }
        }
        gatewayError = nil
        return true
    }

    private static let secretConfigKeys: Set<String> = [
        "bot_token", "app_secret", "secret", "corp_secret", "verification_token", "app_token",
    ]

    private static func resolvingSecrets(_ channel: ChannelConfig) -> ChannelConfig {
        var resolved = channel
        for key in secretConfigKeys {
            if let value = resolved.config[key] {
                resolved.config[key] = SecretStore.resolve(value)
            }
        }
        return resolved
    }

    private static func storedSecretReferences(at path: String) -> Set<String> {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let stored = try? JSONDecoder().decode([ChannelConfig].self, from: data)
        else {
            return []
        }
        return Set(
            stored.flatMap { channel in
                secretConfigKeys.compactMap { key in
                    guard let value = channel.config[key], SecretStore.isReference(value) else { return nil }
                    return value
                }
            })
    }
}
