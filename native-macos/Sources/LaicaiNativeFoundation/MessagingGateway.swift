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
}

public enum ChannelType: String, Codable, Sendable, CaseIterable {
    case telegram = "telegram"
    case feishu = "feishu"
    case wecom = "wecom"
    case slack = "slack"
    case webhook = "webhook"

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
    @Published public private(set) var messageLog: [IncomingMessage] = []
    @Published public private(set) var isRunning: Bool = false

    /// Callback to process an incoming message through the agent
    public var onProcessMessage: ((IncomingMessage) async -> String)?

    private var activeChannels: [UUID: any MessagingChannel] = [:]
    private var httpServer: GatewayHTTPServer?
    private var persistPath: String = ""

    private init() {}

    // MARK: - Lifecycle

    public func start(workspaceRoot: String, port: Int = 18789) {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = root.isEmpty
            ? ((FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory()) as NSString).appendingPathComponent("Laicai")
            : (root as NSString).appendingPathComponent(".laicai")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        persistPath = (dir as NSString).appendingPathComponent("messaging_channels.json")

        loadChannels()

        // Start HTTP webhook server
        httpServer = GatewayHTTPServer(port: port) { [weak self] message in
            await self?.handleIncomingMessage(message)
        }
        httpServer?.start()

        // Connect enabled channels
        for channel in channels where channel.enabled {
            Task { await connectChannel(id: channel.id) }
        }

        isRunning = true
    }

    public func stop() {
        httpServer?.stop()
        for (id, channel) in activeChannels {
            Task { await channel.disconnect() }
            connectedChannels.remove(id)
        }
        activeChannels.removeAll()
        isRunning = false
    }

    // MARK: - Channel Management

    public func addChannel(_ config: ChannelConfig) {
        channels.append(config)
        persist()
        if config.enabled {
            Task { await connectChannel(id: config.id) }
        }
    }

    public func removeChannel(id: UUID) {
        Task { await disconnectChannel(id: id) }
        channels.removeAll { $0.id == id }
        persist()
    }

    public func toggleChannel(id: UUID) {
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        channels[index].enabled.toggle()
        persist()
        if channels[index].enabled {
            Task { await connectChannel(id: id) }
        } else {
            Task { await disconnectChannel(id: id) }
        }
    }

    /// Expose active channel for webhook routing
    public func activeChannelForID(_ id: UUID) -> (any MessagingChannel)? {
        activeChannels[id]
    }

    // MARK: - Connection

    private func connectChannel(id: UUID) async {
        guard let config = channels.first(where: { $0.id == id }) else { return }
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
            return
        }

        channel.onMessageReceived = { [weak self] message in
            Task { @MainActor [weak self] in
                await self?.handleIncomingMessage(message)
            }
        }

        do {
            try await channel.connect()
            activeChannels[id] = channel
            connectedChannels.insert(id)
        } catch {
            // Log connection failure
            print("[Gateway] Failed to connect \(config.type.displayName): \(error)")
        }
    }

    private func disconnectChannel(id: UUID) async {
        if let channel = activeChannels.removeValue(forKey: id) {
            await channel.disconnect()
        }
        connectedChannels.remove(id)
    }

    // MARK: - Message Handling

    private func handleIncomingMessage(_ message: IncomingMessage) async {
        // Security: check allowed senders
        if let config = channels.first(where: { $0.type == message.channel }),
           !config.allowedSenders.isEmpty,
           !config.allowedSenders.contains(message.sender) {
            return // Reject unauthorized sender
        }

        messageLog.append(message)
        if messageLog.count > 200 { messageLog.removeFirst(messageLog.count - 200) }

        // Process through agent
        guard let processor = onProcessMessage else { return }
        let response = await processor(message)

        // Send reply
        if let config = channels.first(where: { $0.type == message.channel }),
           let channel = activeChannels[config.id] {
            try? await channel.sendMessage(response, to: message.sender)
        }
    }

    // MARK: - Persistence

    private func loadChannels() {
        guard !persistPath.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: persistPath)),
              let loaded = try? JSONDecoder().decode([ChannelConfig].self, from: data) else { return }
        channels = loaded
    }

    private func persist() {
        guard !persistPath.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(channels) else { return }
        try? data.write(to: URL(fileURLWithPath: persistPath), options: .atomic)
    }
}

// MARK: - Telegram Channel

public final class TelegramChannel: MessagingChannel, @unchecked Sendable {
    public let channelType: ChannelType = .telegram
    public private(set) var isConnected: Bool = false
    public var onMessageReceived: (@Sendable (IncomingMessage) -> Void)?

    private let botToken: String
    private let allowedChatIDs: [String]
    private var pollingTask: Task<Void, Never>?
    private var lastUpdateID: Int = 0

    init(config: ChannelConfig) {
        self.botToken = config.config["bot_token"] ?? ""
        self.allowedChatIDs = config.allowedSenders
    }

    public func connect() async throws {
        guard !botToken.isEmpty else {
            throw GatewayError.missingConfig("Telegram bot_token 未配置")
        }

        isConnected = true
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollUpdates()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    public func disconnect() async {
        pollingTask?.cancel()
        pollingTask = nil
        isConnected = false
    }

    public func sendMessage(_ text: String, to recipient: String) async throws {
        guard !botToken.isEmpty else { return }
        let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendMessage")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "chat_id": recipient,
            "text": text,
            "parse_mode": "Markdown"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await URLSession.shared.data(for: request)
    }

    private func pollUpdates() async {
        guard !botToken.isEmpty else { return }
        let urlStr = "https://api.telegram.org/bot\(botToken)/getUpdates?offset=\(lastUpdateID + 1)&timeout=10"
        guard let url = URL(string: urlStr) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ok = json["ok"] as? Bool, ok,
                  let results = json["result"] as? [[String: Any]] else { return }

            for update in results {
                if let updateID = update["update_id"] as? Int {
                    lastUpdateID = max(lastUpdateID, updateID)
                }
                guard let msg = update["message"] as? [String: Any],
                      let text = msg["text"] as? String,
                      let chat = msg["chat"] as? [String: Any],
                      let chatID = chat["id"] as? Int else { continue }

                let chatIDStr = "\(chatID)"
                if !allowedChatIDs.isEmpty && !allowedChatIDs.contains(chatIDStr) { continue }

                let from = msg["from"] as? [String: Any]
                let senderName = from?["first_name"] as? String ?? ""

                let incoming = IncomingMessage(
                    channel: .telegram,
                    sender: chatIDStr,
                    senderName: senderName,
                    text: text
                )
                onMessageReceived?(incoming)
            }
        } catch {
            // Polling error, will retry on next tick
        }
    }
}

// MARK: - Feishu Channel

public final class FeishuChannel: MessagingChannel, @unchecked Sendable {
    public let channelType: ChannelType = .feishu
    public private(set) var isConnected: Bool = false
    public var onMessageReceived: (@Sendable (IncomingMessage) -> Void)?

    private let appID: String
    private let appSecret: String
    private let verificationToken: String
    private let encryptKey: String
    private var accessToken: String = ""
    private var tokenExpiresAt: Date = .distantPast
    private var refreshTask: Task<Void, Never>?
    private var processedEventIDs: Set<String> = []

    init(config: ChannelConfig) {
        self.appID = config.config["app_id"] ?? ""
        self.appSecret = config.config["app_secret"] ?? ""
        self.verificationToken = config.config["verification_token"] ?? ""
        self.encryptKey = config.config["encrypt_key"] ?? ""
    }

    public func connect() async throws {
        guard !appID.isEmpty, !appSecret.isEmpty else {
            throw GatewayError.missingConfig("飞书 app_id 或 app_secret 未配置")
        }
        try await refreshToken()
        isConnected = true

        // Auto-refresh token every 90 minutes (token expires in 2 hours)
        refreshTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5400)) // 90 min
                try? await self?.refreshToken()
            }
        }
    }

    public func disconnect() async {
        refreshTask?.cancel()
        refreshTask = nil
        isConnected = false
        accessToken = ""
    }

    private func refreshToken() async throws {
        let url = URL(string: "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let body = ["app_id": appID, "app_secret": appSecret]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = json["tenant_access_token"] as? String,
           let expire = json["expire"] as? Int {
            accessToken = token
            tokenExpiresAt = Date().addingTimeInterval(Double(expire))
        }
    }

    private func ensureToken() async {
        if Date() >= tokenExpiresAt.addingTimeInterval(-120) {
            try? await refreshToken()
        }
    }

    public func sendMessage(_ text: String, to recipient: String) async throws {
        await ensureToken()
        guard !accessToken.isEmpty else { return }

        // Determine receive_id_type: chat_id for groups, open_id for DMs
        let idType = recipient.hasPrefix("oc_") ? "chat_id" : "open_id"
        let url = URL(string: "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=\(idType)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        // Use rich text for long messages, plain text for short
        let msgType: String
        let contentStr: String
        if text.count > 200 || text.contains("\n") {
            // Post (rich text)
            let lines = text.components(separatedBy: "\n")
            var elements: [[Any]] = []
            for line in lines {
                elements.append([["tag": "text", "text": line]])
            }
            let post: [String: Any] = [
                "zh_cn": [
                    "title": "",
                    "content": elements
                ]
            ]
            msgType = "post"
            contentStr = (try? JSONSerialization.data(withJSONObject: post)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        } else {
            msgType = "text"
            let content: [String: Any] = ["text": text]
            contentStr = (try? JSONSerialization.data(withJSONObject: content)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }

        let body: [String: Any] = [
            "receive_id": recipient,
            "msg_type": msgType,
            "content": contentStr
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, resp) = try await URLSession.shared.data(for: request)
        // Retry once on token expiry
        if let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 401 || httpResp.statusCode == 99991663 {
            try await refreshToken()
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            _ = try await URLSession.shared.data(for: request)
        }
        // Check for error in response
        if let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
           let code = json["code"] as? Int, code != 0 {
            let msg = json["msg"] as? String ?? "未知错误"
            print("[Feishu] 发送消息失败: code=\(code) msg=\(msg)")
        }
    }

    /// Handle incoming webhook event from Feishu
    public func handleWebhookEvent(_ body: [String: Any]) -> String? {
        // URL verification challenge
        if let challenge = body["challenge"] as? String {
            return "{\"challenge\":\"\(challenge)\"}"
        }

        // Verify token if configured
        if !verificationToken.isEmpty {
            if let token = body["token"] as? String, token != verificationToken {
                return nil // reject
            }
        }

        // Event callback v2.0
        guard let header = body["header"] as? [String: Any],
              let eventType = header["event_type"] as? String else {
            // Try v1.0 format
            return handleV1Event(body)
        }

        let eventID = header["event_id"] as? String ?? UUID().uuidString

        // Deduplicate
        if processedEventIDs.contains(eventID) { return "{\"ok\":true}" }
        processedEventIDs.insert(eventID)
        if processedEventIDs.count > 500 { processedEventIDs.removeFirst() }

        guard let event = body["event"] as? [String: Any] else { return "{\"ok\":true}" }

        switch eventType {
        case "im.message.receive_v1":
            handleMessageEvent(event, eventID: eventID)
        default:
            break
        }

        return "{\"ok\":true}"
    }

    private func handleMessageEvent(_ event: [String: Any], eventID: String) {
        guard let message = event["message"] as? [String: Any],
              let msgType = message["message_type"] as? String,
              let content = message["content"] as? String else { return }

        // Only handle text messages for now
        guard msgType == "text" else { return }

        // Parse content JSON
        guard let contentData = content.data(using: .utf8),
              let contentJSON = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any],
              let text = contentJSON["text"] as? String else { return }

        // Extract sender info
        let sender = event["sender"] as? [String: Any]
        let senderID = (sender?["sender_id"] as? [String: Any])?["open_id"] as? String ?? ""
        let chatID = message["chat_id"] as? String ?? senderID

        // Strip @bot mentions
        var cleanText = text
        if let mentionRange = cleanText.range(of: "@\\w+", options: .regularExpression) {
            cleanText.removeSubrange(mentionRange)
        }
        cleanText = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return }

        let incoming = IncomingMessage(
            id: eventID,
            channel: .feishu,
            sender: chatID,
            senderName: (sender?["sender_id"] as? [String: Any])?["user_id"] as? String ?? "",
            text: cleanText,
            metadata: ["message_id": message["message_id"] as? String ?? ""]
        )
        onMessageReceived?(incoming)
    }

    private func handleV1Event(_ body: [String: Any]) -> String? {
        guard let event = body["event"] as? [String: Any],
              let msgType = event["msg_type"] as? String, msgType == "text",
              let text = (event["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return "{\"ok\":true}" }

        let chatID = event["open_chat_id"] as? String ?? event["open_id"] as? String ?? ""
        let incoming = IncomingMessage(
            channel: .feishu,
            sender: chatID,
            senderName: event["user_open_id"] as? String ?? "",
            text: text
        )
        onMessageReceived?(incoming)
        return "{\"ok\":true}"
    }
}

// MARK: - WeCom Channel

public final class WeComChannel: MessagingChannel, @unchecked Sendable {
    public let channelType: ChannelType = .wecom
    public private(set) var isConnected: Bool = false
    public var onMessageReceived: (@Sendable (IncomingMessage) -> Void)?

    private let corpID: String
    private let secret: String
    private let agentID: String
    private var accessToken: String = ""

    init(config: ChannelConfig) {
        self.corpID = config.config["corp_id"] ?? ""
        self.secret = config.config["secret"] ?? ""
        self.agentID = config.config["agent_id"] ?? ""
    }

    public func connect() async throws {
        guard !corpID.isEmpty, !secret.isEmpty else {
            throw GatewayError.missingConfig("企业微信 corp_id 或 secret 未配置")
        }
        let urlStr = "https://qyapi.weixin.qq.com/cgi-bin/gettoken?corpid=\(corpID)&corpsecret=\(secret)"
        guard let url = URL(string: urlStr) else { throw GatewayError.missingConfig("URL无效") }
        let (data, _) = try await URLSession.shared.data(from: url)
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = json["access_token"] as? String {
            accessToken = token
            isConnected = true
        }
    }

    public func disconnect() async {
        isConnected = false
        accessToken = ""
    }

    public func sendMessage(_ text: String, to recipient: String) async throws {
        guard !accessToken.isEmpty else { return }
        let url = URL(string: "https://qyapi.weixin.qq.com/cgi-bin/message/send?access_token=\(accessToken)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "touser": recipient,
            "msgtype": "text",
            "agentid": Int(agentID) ?? 0,
            "text": ["content": text]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await URLSession.shared.data(for: request)
    }
}

// MARK: - Slack Channel

public final class SlackChannel: MessagingChannel, @unchecked Sendable {
    public let channelType: ChannelType = .slack
    public private(set) var isConnected: Bool = false
    public var onMessageReceived: (@Sendable (IncomingMessage) -> Void)?

    private let botToken: String

    init(config: ChannelConfig) {
        self.botToken = config.config["bot_token"] ?? ""
    }

    public func connect() async throws {
        guard !botToken.isEmpty else {
            throw GatewayError.missingConfig("Slack bot_token 未配置")
        }
        isConnected = true
    }

    public func disconnect() async {
        isConnected = false
    }

    public func sendMessage(_ text: String, to recipient: String) async throws {
        guard !botToken.isEmpty else { return }
        let url = URL(string: "https://slack.com/api/chat.postMessage")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(botToken)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["channel": recipient, "text": text]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await URLSession.shared.data(for: request)
    }
}

// MARK: - Gateway HTTP Server (Webhook receiver)

public final class GatewayHTTPServer: @unchecked Sendable {
    private let port: Int
    private let handler: @Sendable (IncomingMessage) async -> Void
    private var serverSocket: Int32 = -1
    private var listenTask: Task<Void, Never>?

    init(port: Int, handler: @escaping @Sendable (IncomingMessage) async -> Void) {
        self.port = port
        self.handler = handler
    }

    func start() {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else { return }

        var yes: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(serverSocket)
            serverSocket = -1
            return
        }

        listen(serverSocket, 5)

        listenTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.serverSocket >= 0 {
                var clientAddr = sockaddr_in()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientSocket = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        accept(self.serverSocket, $0, &clientAddrLen)
                    }
                }
                guard clientSocket >= 0 else { continue }

                Task.detached { [weak self] in
                    await self?.handleConnection(clientSocket)
                }
            }
        }
    }

    func stop() {
        listenTask?.cancel()
        listenTask = nil
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
    }

    private func handleConnection(_ socket: Int32) async {
        defer { close(socket) }

        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = recv(socket, &buffer, buffer.count, 0)
        guard bytesRead > 0 else { return }

        let requestStr = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""

        // Route: POST /feishu/event — Feishu event subscription callback
        let isFeishuEvent = requestStr.hasPrefix("POST /feishu")
        // Route: POST /webhook or /message — generic webhook
        let isGenericWebhook = requestStr.hasPrefix("POST /webhook") || requestStr.hasPrefix("POST /message")

        guard isFeishuEvent || isGenericWebhook else {
            let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
            _ = response.withCString { send(socket, $0, strlen($0), 0) }
            return
        }

        // Extract JSON body
        if let bodyStart = requestStr.range(of: "\r\n\r\n") {
            let body = String(requestStr[bodyStart.upperBound...])
            if let data = body.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                if isFeishuEvent {
                    // Delegate to FeishuChannel for event parsing + challenge response
                    let gateway = await MessagingGateway.shared
                    let feishuConfig = await gateway.channels.first { $0.type == .feishu }
                    if let config = feishuConfig,
                       let channel = await gateway.activeChannelForID(config.id) as? FeishuChannel {
                        if let challengeResp = channel.handleWebhookEvent(json) {
                            let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n\(challengeResp)"
                            _ = response.withCString { send(socket, $0, strlen($0), 0) }
                            return
                        }
                    }
                } else {
                    // Generic webhook
                    let text = json["text"] as? String ?? json["message"] as? String ?? ""
                    let sender = json["sender"] as? String ?? json["from"] as? String ?? "webhook"
                    let channel = json["channel"] as? String

                    let channelType: ChannelType = {
                        switch channel {
                        case "telegram": return .telegram
                        case "feishu": return .feishu
                        case "wecom": return .wecom
                        case "slack": return .slack
                        default: return .webhook
                        }
                    }()

                    let message = IncomingMessage(
                        channel: channelType,
                        sender: sender,
                        text: text
                    )
                    await handler(message)
                }
            }
        }

        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"ok\":true}"
        _ = response.withCString { send(socket, $0, strlen($0), 0) }
    }
}

// MARK: - Gateway Error

public enum GatewayError: LocalizedError {
    case missingConfig(String)
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingConfig(let detail): return "配置缺失：\(detail)"
        case .connectionFailed(let detail): return "连接失败：\(detail)"
        }
    }
}
