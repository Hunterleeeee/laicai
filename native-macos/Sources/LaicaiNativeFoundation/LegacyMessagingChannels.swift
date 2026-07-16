import Foundation
import LaicaiNativeDomain

// MARK: - WeCom Channel

public final class WeComChannel: MessagingChannel, Sendable {
    public let channelType: ChannelType = .wecom
    public var isConnected: Bool { state.withValue { $0.isConnected } }
    public var onMessageReceived: (@Sendable (IncomingMessage) -> Void)? {
        get { state.withValue { $0.onMessageReceived } }
        set { state.withValue { $0.onMessageReceived = newValue } }
    }
    public var onConnectionStateChanged: (@Sendable (Bool, String?) -> Void)? {
        get { state.withValue { $0.onConnectionStateChanged } }
        set { state.withValue { $0.onConnectionStateChanged = newValue } }
    }

    private let corpID: String
    private let secret: String
    private let agentID: String
    private struct State {
        var isConnected = false
        var onMessageReceived: (@Sendable (IncomingMessage) -> Void)?
        var onConnectionStateChanged: (@Sendable (Bool, String?) -> Void)?
        var accessToken: String = ""
    }
    private let state = Locked(State())

    init(config: ChannelConfig) {
        self.corpID = config.config["corp_id"] ?? ""
        self.secret = config.config["corp_secret"] ?? config.config["secret"] ?? ""
        self.agentID = config.config["agent_id"] ?? ""
    }

    public func connect() async throws {
        guard !corpID.isEmpty, !secret.isEmpty else {
            throw GatewayError.missingConfig("企业微信 corp_id 或 secret 未配置")
        }
        throw GatewayError.connectionFailed("企业微信入站消息接收尚未实现，请使用 Webhook 或飞书/Telegram。")
    }

    public func disconnect() async {
        let callback = state.withValue { state in
            state.isConnected = false
            state.accessToken = ""
            return state.onConnectionStateChanged
        }
        callback?(false, nil)
    }

    public func sendMessage(_ text: String, to recipient: String) async throws {
        let token = state.withValue { $0.accessToken }
        guard !token.isEmpty else { return }
        let url = URL(string: "https://qyapi.weixin.qq.com/cgi-bin/message/send?access_token=\(token)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "touser": recipient,
            "msgtype": "text",
            "agentid": Int(agentID) ?? 0,
            "text": ["content": text],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await NetworkDefaults.ephemeralSession.data(for: request)
    }
}

// MARK: - Slack Channel

public final class SlackChannel: MessagingChannel, Sendable {
    public let channelType: ChannelType = .slack
    public var isConnected: Bool { state.withValue { $0.isConnected } }
    public var onMessageReceived: (@Sendable (IncomingMessage) -> Void)? {
        get { state.withValue { $0.onMessageReceived } }
        set { state.withValue { $0.onMessageReceived = newValue } }
    }
    public var onConnectionStateChanged: (@Sendable (Bool, String?) -> Void)? {
        get { state.withValue { $0.onConnectionStateChanged } }
        set { state.withValue { $0.onConnectionStateChanged = newValue } }
    }

    private let botToken: String
    private struct State {
        var isConnected = false
        var onMessageReceived: (@Sendable (IncomingMessage) -> Void)?
        var onConnectionStateChanged: (@Sendable (Bool, String?) -> Void)?
    }
    private let state = Locked(State())

    init(config: ChannelConfig) {
        self.botToken = config.config["bot_token"] ?? ""
    }

    public func connect() async throws {
        guard !botToken.isEmpty else {
            throw GatewayError.missingConfig("Slack bot_token 未配置")
        }
        throw GatewayError.connectionFailed("Slack 入站消息接收尚未实现，请使用 Webhook 或飞书/Telegram。")
    }

    public func disconnect() async {
        let callback = state.withValue { state in
            state.isConnected = false
            return state.onConnectionStateChanged
        }
        callback?(false, nil)
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
        _ = try await NetworkDefaults.ephemeralSession.data(for: request)
    }
}
