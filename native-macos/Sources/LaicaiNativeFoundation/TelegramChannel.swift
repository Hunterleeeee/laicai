import Foundation
import LaicaiNativeDomain

// MARK: - Telegram Channel

public final class TelegramChannel: MessagingChannel, Sendable {
    public let channelType: ChannelType = .telegram
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
    private let allowedChatIDs: [String]
    private let session: URLSession
    private struct State {
        var isConnected = false
        var onMessageReceived: (@Sendable (IncomingMessage) -> Void)?
        var onConnectionStateChanged: (@Sendable (Bool, String?) -> Void)?
        var pollingTask: Task<Void, Never>?
        var lastUpdateID: Int = 0
    }
    private let state = Locked(State())

    init(config: ChannelConfig, session: URLSession = NetworkDefaults.ephemeralSession) {
        self.botToken = config.config["bot_token"] ?? ""
        self.allowedChatIDs = config.allowedSenders
        self.session = session
    }

    public func connect() async throws {
        guard !botToken.isEmpty else {
            throw GatewayError.missingConfig("Telegram bot_token 未配置")
        }

        let validationURL = URL(string: "https://api.telegram.org/bot\(botToken)/getMe")!
        let (data, response) = try await session.data(from: validationURL)
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            json["ok"] as? Bool == true
        else {
            throw GatewayError.connectionFailed("Telegram Bot Token 验证失败")
        }

        let callback = state.withValue { state in
            state.isConnected = true
            return state.onConnectionStateChanged
        }
        callback?(true, nil)
        let task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollUpdates()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        state.withValue { $0.pollingTask = task }
    }

    public func disconnect() async {
        let snapshot = state.withValue { state in
            let task = state.pollingTask
            state.pollingTask = nil
            state.isConnected = false
            return (task, state.onConnectionStateChanged)
        }
        snapshot.0?.cancel()
        snapshot.1?(false, nil)
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
            "parse_mode": "Markdown",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            json["ok"] as? Bool == true
        else {
            throw GatewayError.connectionFailed("Telegram 消息发送失败")
        }
    }

    private func pollUpdates() async {
        guard !botToken.isEmpty else { return }
        let offset = state.withValue { $0.lastUpdateID + 1 }
        let urlStr = "https://api.telegram.org/bot\(botToken)/getUpdates?offset=\(offset)&timeout=10"
        guard let url = URL(string: urlStr) else { return }

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                (200...299).contains(httpResponse.statusCode)
            else {
                throw GatewayError.connectionFailed(
                    "Telegram 轮询返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                )
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let isOK = json["ok"] as? Bool, isOK,
                let results = json["result"] as? [[String: Any]]
            else {
                throw GatewayError.connectionFailed("Telegram 轮询响应格式无效")
            }

            let callback = state.withValue { state in
                let wasDisconnected = !state.isConnected
                state.isConnected = true
                return wasDisconnected ? state.onConnectionStateChanged : nil
            }
            callback?(true, nil)

            for update in results {
                if let updateID = update["update_id"] as? Int {
                    state.withValue { $0.lastUpdateID = max($0.lastUpdateID, updateID) }
                }
                guard let msg = update["message"] as? [String: Any],
                    let text = msg["text"] as? String,
                    let chat = msg["chat"] as? [String: Any],
                    let chatID = chat["id"] as? Int
                else { continue }

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
            let callback = state.withValue { state in
                state.isConnected = false
                return state.onConnectionStateChanged
            }
            callback?(false, "Telegram 轮询失败：\(error.localizedDescription)")
        }
    }
}
