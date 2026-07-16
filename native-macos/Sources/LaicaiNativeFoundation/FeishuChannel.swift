import Foundation
import LaicaiNativeDomain

// MARK: - Feishu Channel (WebSocket Long Connection)

/// Feishu channel using WebSocket long connection mode.
/// No public IP or webhook callback required — the client connects outbound to Feishu's WSS server.
/// Protocol reference: larksuite/oapi-sdk-go ws package (pbbp2 binary frames).
public final class FeishuChannel: MessagingChannel, Sendable {
    public let channelType: ChannelType = .feishu
    public var isConnected: Bool { state.withValue { $0.isConnected } }
    public var onMessageReceived: (@Sendable (IncomingMessage) -> Void)? {
        get { state.withValue { $0.onMessageReceived } }
        set { state.withValue { $0.onMessageReceived = newValue } }
    }
    public var onConnectionStateChanged: (@Sendable (Bool, String?) -> Void)? {
        get { state.withValue { $0.onConnectionStateChanged } }
        set { state.withValue { $0.onConnectionStateChanged = newValue } }
    }

    private let appID: String
    private let appSecret: String
    private struct State {
        var isConnected = false
        var onMessageReceived: (@Sendable (IncomingMessage) -> Void)?
        var onConnectionStateChanged: (@Sendable (Bool, String?) -> Void)?
        var accessToken: String = ""
        var tokenExpiresAt: Date = .distantPast
        var wsTask: URLSessionWebSocketTask?
        var pingTask: Task<Void, Never>?
        var receiveTask: Task<Void, Never>?
        var tokenRefreshTask: Task<Void, Never>?
        var serviceID: Int32 = 0
        var pingInterval: TimeInterval = 120  // default 2 min
        var autoReconnect = true
        var processedEventIDs: Set<String> = []
        var fragmentCache: [String: (total: Int, parts: [Int: Data])] = [:]
    }
    private let state = Locked(State())

    private static let wsEndpoint = "https://open.feishu.cn/callback/ws/endpoint"
    private static let tokenEndpoint = "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal"
    private static let sendMessageEndpoint = "https://open.feishu.cn/open-apis/im/v1/messages"

    init(config: ChannelConfig) {
        self.appID = config.config["app_id"] ?? ""
        self.appSecret = config.config["app_secret"] ?? ""
    }

    // MARK: - Lifecycle

    public func connect() async throws {
        guard !appID.isEmpty, !appSecret.isEmpty else {
            throw GatewayError.missingConfig("飞书 app_id 或 app_secret 未配置")
        }

        try await refreshToken()

        // Get WebSocket endpoint URL
        let wssURL = try await getWSEndpoint()
        LaicaiLog.info("Feishu connecting to \(wssURL)")

        // Extract serviceID from URL query
        if let components = URLComponents(string: wssURL),
            let sid = components.queryItems?.first(where: { $0.name == "service_id" })?.value,
            let sidInt = Int32(sid)
        {
            state.withValue { $0.serviceID = sidInt }
        }

        // Connect WebSocket
        let session = NetworkDefaults.webSocketSession
        guard let url = URL(string: wssURL) else {
            throw GatewayError.missingConfig("无效的 WebSocket URL")
        }
        let webSocket = session.webSocketTask(with: url)
        webSocket.resume()
        let callback = state.withValue { state in
            state.wsTask = webSocket
            state.isConnected = true
            state.autoReconnect = true
            return state.onConnectionStateChanged
        }
        callback?(true, nil)
        LaicaiLog.info("Feishu WebSocket connected")

        // Start receive loop
        let receiveTask = Task.detached { [weak self] in
            await self?.receiveLoop()
            return
        }
        state.withValue { $0.receiveTask = receiveTask }

        // Start ping loop
        let pingTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let interval = self.state.withValue { $0.pingInterval }
                try? await Task.sleep(for: .seconds(interval))
                await self.sendPing()
            }
        }
        state.withValue { $0.pingTask = pingTask }

        // Auto-refresh token every 90 minutes
        let tokenRefreshTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5400))
                try? await self?.refreshToken()
            }
        }
        state.withValue { $0.tokenRefreshTask = tokenRefreshTask }
    }

    public func disconnect() async {
        let snapshot = state.withValue { state in
            state.autoReconnect = false
            let tasks = (state.pingTask, state.receiveTask, state.tokenRefreshTask, state.wsTask)
            state.pingTask = nil
            state.receiveTask = nil
            state.tokenRefreshTask = nil
            state.wsTask = nil
            state.isConnected = false
            state.accessToken = ""
            state.tokenExpiresAt = .distantPast
            state.fragmentCache.removeAll()
            return (tasks, state.onConnectionStateChanged)
        }
        snapshot.0.0?.cancel()
        snapshot.0.1?.cancel()
        snapshot.0.2?.cancel()
        snapshot.0.3?.cancel(with: .goingAway, reason: nil)
        snapshot.1?(false, nil)
        LaicaiLog.info("Feishu disconnected")
    }

    // MARK: - Token Management

    private func refreshToken() async throws {
        let url = URL(string: Self.tokenEndpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let body = ["app_id": appID, "app_secret": appSecret]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await NetworkDefaults.ephemeralSession.data(for: request)
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = json["tenant_access_token"] as? String,
            let expire = json["expire"] as? Int
        {
            state.withValue {
                $0.accessToken = token
                $0.tokenExpiresAt = Date().addingTimeInterval(Double(expire))
            }
            LaicaiLog.info("Feishu token refreshed, expires in \(expire)s")
        } else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["msg"] as? String ?? "unknown"
            throw GatewayError.missingConfig("获取飞书 token 失败: \(msg)")
        }
    }

    private func ensureToken() async {
        let shouldRefresh = state.withValue { Date() >= $0.tokenExpiresAt.addingTimeInterval(-120) }
        if shouldRefresh {
            try? await refreshToken()
        }
    }

    // MARK: - WebSocket Endpoint

    private func getWSEndpoint() async throws -> String {
        let url = URL(string: Self.wsEndpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let body = ["AppID": appID, "AppSecret": appSecret]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await NetworkDefaults.ephemeralSession.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let code = json["code"] as? Int, code == 0,
            let dataObj = json["data"] as? [String: Any],
            let wssURL = dataObj["URL"] as? String, !wssURL.isEmpty
        else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["msg"] as? String ?? "unknown"
            throw GatewayError.missingConfig("获取飞书 WebSocket 地址失败: \(msg)")
        }

        // Apply server-pushed client config
        if let clientConfig = dataObj["ClientConfig"] as? [String: Any] {
            if let pingInterval = clientConfig["PingInterval"] as? Int, pingInterval > 0 {
                state.withValue { $0.pingInterval = TimeInterval(pingInterval) }
            }
        }

        return wssURL
    }

    // MARK: - WebSocket Receive Loop

    private func receiveLoop() async {
        guard let webSocket = state.withValue({ $0.wsTask }) else { return }
        while !Task.isCancelled {
            do {
                let message = try await webSocket.receive()
                switch message {
                case .data(let data):
                    handleBinaryFrame(data)
                case .string(let text):
                    // Feishu normally sends binary, but handle text as fallback
                    if let data = text.data(using: .utf8) {
                        handleTextMessage(data)
                    }
                @unknown default:
                    break
                }
            } catch {
                LaicaiLog.error("Feishu receive error: \(error)")
                let snapshot = state.withValue { state in
                    state.isConnected = false
                    let tasks = (state.pingTask, state.tokenRefreshTask, state.wsTask)
                    state.pingTask = nil
                    state.tokenRefreshTask = nil
                    state.wsTask = nil
                    return (state.autoReconnect, tasks, state.onConnectionStateChanged)
                }
                snapshot.1.0?.cancel()
                snapshot.1.1?.cancel()
                snapshot.1.2?.cancel(with: .goingAway, reason: nil)
                snapshot.2?(false, "飞书连接中断：\(error.localizedDescription)")
                if snapshot.0 {
                    LaicaiLog.info("Feishu attempting reconnect in 5s")
                    try? await Task.sleep(for: .seconds(5))
                    do {
                        try await connect()
                    } catch {
                        LaicaiLog.error("Feishu reconnect failed: \(error)")
                        let callback = state.withValue { $0.onConnectionStateChanged }
                        callback?(false, "飞书重连失败：\(error.localizedDescription)")
                    }
                }
                return
            }
        }
    }

    // MARK: - Protobuf Frame Codec (pbbp2)

    /// Minimal protobuf frame: field 1=method(varint), 2=service(varint), 3=headers(repeated LDel), 4=payload(bytes)
    /// Header: field 1=key(string), 2=value(string)

    private func handleBinaryFrame(_ data: Data) {
        let frame = FeishuFrame.decode(data)

        switch frame.method {
        case 0:  // Control
            handleControlFrame(frame)
        case 1:  // Data
            handleDataFrame(frame)
        default:
            break
        }
    }

    private func handleControlFrame(_ frame: FeishuFrame) {
        let frameType = frame.headerValue(for: "type")
        if frameType == "pong" {
            // May contain updated client config in payload
            if !frame.payload.isEmpty,
                let json = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
                let pingInterval = json["PingInterval"] as? Int, pingInterval > 0
            {
                state.withValue { $0.pingInterval = TimeInterval(pingInterval) }
            }
        }
    }

    private func handleDataFrame(_ frame: FeishuFrame) {
        let sum = Int(frame.headerValue(for: "sum") ?? "1") ?? 1
        let seq = Int(frame.headerValue(for: "seq") ?? "0") ?? 0
        let msgID = frame.headerValue(for: "message_id") ?? UUID().uuidString
        let frameType = frame.headerValue(for: "type") ?? ""

        var payload = frame.payload

        // Fragment reassembly
        if sum > 1 {
            guard
                let assembled = state.withValue({ state -> Data? in
                    if state.fragmentCache[msgID] == nil {
                        state.fragmentCache[msgID] = (total: sum, parts: [:])
                    }
                    state.fragmentCache[msgID]?.parts[seq] = payload

                    guard let cached = state.fragmentCache[msgID],
                        cached.parts.count == sum
                    else { return nil }

                    var assembled = Data()
                    for fragmentIndex in 0..<sum {
                        if let part = cached.parts[fragmentIndex] {
                            assembled.append(part)
                        }
                    }
                    state.fragmentCache.removeValue(forKey: msgID)
                    return assembled
                })
            else {
                return
            }
            payload = assembled
        }

        // Send ACK response
        sendAck(frame: frame)

        // Parse event
        if frameType == "event" {
            handleEvent(payload, eventID: msgID)
        }
    }

    private func handleEvent(_ payload: Data, eventID: String) {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }

        // Deduplicate
        let eid = (json["header"] as? [String: Any])?["event_id"] as? String ?? eventID
        let shouldProcess = state.withValue { state in
            if state.processedEventIDs.contains(eid) { return false }
            state.processedEventIDs.insert(eid)
            if state.processedEventIDs.count > 500 { state.processedEventIDs.removeFirst() }
            return true
        }
        guard shouldProcess else { return }

        // Check event type
        guard let header = json["header"] as? [String: Any],
            let eventType = header["event_type"] as? String,
            eventType == "im.message.receive_v1",
            let event = json["event"] as? [String: Any]
        else { return }

        handleMessageEvent(event, eventID: eid)
    }

    private func handleMessageEvent(_ event: [String: Any], eventID: String) {
        guard let message = event["message"] as? [String: Any],
            let msgType = message["message_type"] as? String,
            let content = message["content"] as? String
        else { return }

        // Only handle text messages for now
        guard msgType == "text" else { return }

        guard let contentData = content.data(using: .utf8),
            let contentJSON = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any],
            let text = contentJSON["text"] as? String
        else { return }

        let sender = event["sender"] as? [String: Any]
        let senderID = (sender?["sender_id"] as? [String: Any])?["open_id"] as? String ?? ""
        let chatID = message["chat_id"] as? String ?? senderID

        // Strip @bot mentions
        var cleanText = text
        if let mentionRange = cleanText.range(of: "@_all|@_user_\\d+", options: .regularExpression) {
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

    // MARK: - Send Messages (via REST API)

    public func sendMessage(_ text: String, to recipient: String) async throws {
        await ensureToken()
        var token = state.withValue { $0.accessToken }
        guard !token.isEmpty else { return }

        let idType = recipient.hasPrefix("oc_") ? "chat_id" : "open_id"
        let url = URL(string: "\(Self.sendMessageEndpoint)?receive_id_type=\(idType)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let msgType: String
        let contentStr: String
        if text.count > 200 || text.contains("\n") {
            let lines = text.components(separatedBy: "\n")
            var elements: [[Any]] = []
            for line in lines {
                elements.append([["tag": "text", "text": line]])
            }
            let post: [String: Any] = ["zh_cn": ["title": "", "content": elements] as [String: Any]]
            msgType = "post"
            contentStr = (try? JSONSerialization.data(withJSONObject: post)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        } else {
            msgType = "text"
            let content: [String: Any] = ["text": text]
            contentStr = (try? JSONSerialization.data(withJSONObject: content)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }

        let body: [String: Any] = ["receive_id": recipient, "msg_type": msgType, "content": contentStr]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, resp) = try await NetworkDefaults.ephemeralSession.data(for: request)
        if let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 401 {
            try await refreshToken()
            token = state.withValue { $0.accessToken }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            _ = try await NetworkDefaults.ephemeralSession.data(for: request)
            return
        }
        if let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
            let code = json["code"] as? Int, code != 0
        {
            let msg = json["msg"] as? String ?? "未知错误"
            LaicaiLog.error("Feishu 发送消息失败: code=\(code) msg=\(msg)")
        }
    }

    // MARK: - Ping / ACK

    private func sendPing() async {
        let (serviceID, wsTask) = state.withValue { ($0.serviceID, $0.wsTask) }
        let frame = FeishuFrame(method: 0, service: serviceID, headers: [("type", "ping")], payload: Data())
        let data = frame.encode()
        try? await wsTask?.send(.data(data))
    }

    private func sendAck(frame: FeishuFrame) {
        let response: [String: Any] = ["code": 200]
        let payload = (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
        let ackFrame = FeishuFrame(method: frame.method, service: frame.service, headers: frame.headers, payload: payload)
        let data = ackFrame.encode()
        let wsTask = state.withValue { $0.wsTask }
        Task { try? await wsTask?.send(.data(data)) }
    }

    // MARK: - Fallback: handle text/JSON WebSocket messages

    private func handleTextMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        // Some Feishu SDK versions may send JSON directly
        if let header = json["header"] as? [String: Any],
            let eventType = header["event_type"] as? String,
            eventType == "im.message.receive_v1",
            let event = json["event"] as? [String: Any]
        {
            let eid = (header["event_id"] as? String) ?? UUID().uuidString
            handleMessageEvent(event, eventID: eid)
        }
    }
}

// MARK: - Feishu Protobuf Frame (pbbp2)

/// Minimal protobuf wire format encoder/decoder for Feishu WebSocket frames.
/// Field layout: 1=method(varint), 2=service(varint), 3=headers(repeated LDel of Header), 4=payload(bytes)
/// Header sub-message: 1=key(string), 2=value(string)
private struct FeishuProtobufTag {
    let fieldNumber: Int
    let wireType: Int
    let newOffset: Int
}

private struct FeishuFrame {
    var method: Int32 = 0  // 0=control, 1=data
    var service: Int32 = 0
    var headers: [(String, String)] = []
    var payload: Data = Data()

    func headerValue(for key: String) -> String? {
        headers.first(where: { $0.0 == key })?.1
    }

    // MARK: Encode

    func encode() -> Data {
        var buf = Data()
        // Field 1: method (varint)
        if method != 0 {
            buf.appendVarintField(fieldNumber: 1, value: UInt64(method))
        }
        // Field 2: service (varint)
        if service != 0 {
            buf.appendVarintField(fieldNumber: 2, value: UInt64(service))
        }
        // Field 3: headers (repeated length-delimited)
        for (key, value) in headers {
            var headerBuf = Data()
            headerBuf.appendStringField(fieldNumber: 1, value: key)
            headerBuf.appendStringField(fieldNumber: 2, value: value)
            buf.appendLDelField(fieldNumber: 3, value: headerBuf)
        }
        // Field 4: payload (bytes)
        if !payload.isEmpty {
            buf.appendLDelField(fieldNumber: 4, value: payload)
        }
        return buf
    }

    // MARK: Decode

    static func decode(_ data: Data) -> FeishuFrame {
        var frame = FeishuFrame()
        var offset = 0
        let bytes = [UInt8](data)

        while offset < bytes.count {
            guard let tag = readTag(bytes, offset: offset) else { break }
            offset = tag.newOffset
            guard let newOffset = decodeField(tag, bytes: bytes, offset: offset, frame: &frame) else { break }
            offset = newOffset
        }
        return frame
    }

    private static func decodeField(
        _ tag: FeishuProtobufTag,
        bytes: [UInt8],
        offset: Int,
        frame: inout FeishuFrame
    ) -> Int? {
        switch (tag.fieldNumber, tag.wireType) {
        case (1, 0):  // method: varint
            guard let (val, newOff) = readVarint(bytes, offset: offset) else { return nil }
            frame.method = Int32(val)
            return newOff
        case (2, 0):  // service: varint
            guard let (val, newOff) = readVarint(bytes, offset: offset) else { return nil }
            frame.service = Int32(val)
            return newOff
        case (3, 2):  // header: length-delimited
            guard let (headerData, newOff) = readLDel(bytes, offset: offset) else { return nil }
            frame.headers.append(decodeHeader(headerData))
            return newOff
        case (4, 2):  // payload: length-delimited
            guard let (payloadData, newOff) = readLDel(bytes, offset: offset) else { return nil }
            frame.payload = Data(payloadData)
            return newOff
        default:
            return skipUnknownField(wireType: tag.wireType, bytes: bytes, offset: offset)
        }
    }

    private static func skipUnknownField(wireType: Int, bytes: [UInt8], offset: Int) -> Int? {
        switch wireType {
        case 0:
            return readVarint(bytes, offset: offset)?.1
        case 2:
            return readLDel(bytes, offset: offset)?.1
        case 5:
            return offset + 4
        case 1:
            return offset + 8
        default:
            return nil
        }
    }

    private static func decodeHeader(_ bytes: [UInt8]) -> (String, String) {
        var key = ""
        var value = ""
        var offset = 0
        while offset < bytes.count {
            guard let tag = readTag(bytes, offset: offset), tag.wireType == 2 else { break }
            offset = tag.newOffset
            guard let (strBytes, newOff) = readLDel(bytes, offset: offset) else { break }
            offset = newOff
            let str = String(bytes: strBytes, encoding: .utf8) ?? ""
            if tag.fieldNumber == 1 {
                key = str
            } else if tag.fieldNumber == 2 {
                value = str
            }
        }
        return (key, value)
    }

    // MARK: Protobuf primitives

    private static func readTag(_ bytes: [UInt8], offset: Int) -> FeishuProtobufTag? {
        guard let (val, newOff) = readVarint(bytes, offset: offset) else { return nil }
        let wireType = Int(val & 0x07)
        let fieldNumber = Int(val >> 3)
        return FeishuProtobufTag(fieldNumber: fieldNumber, wireType: wireType, newOffset: newOff)
    }

    private static func readVarint(_ bytes: [UInt8], offset: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var byteIndex = offset
        while byteIndex < bytes.count {
            let byte = UInt64(bytes[byteIndex])
            result |= (byte & 0x7F) << shift
            byteIndex += 1
            if byte & 0x80 == 0 { return (result, byteIndex) }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    private static func readLDel(_ bytes: [UInt8], offset: Int) -> ([UInt8], Int)? {
        guard let (len, dataStart) = readVarint(bytes, offset: offset) else { return nil }
        let length = Int(len)
        guard dataStart + length <= bytes.count else { return nil }
        return (Array(bytes[dataStart..<(dataStart + length)]), dataStart + length)
    }
}

// MARK: - Data+Protobuf helpers

extension Data {
    fileprivate mutating func appendVarint(_ value: UInt64) {
        var remainingValue = value
        while remainingValue > 0x7F {
            append(UInt8(remainingValue & 0x7F) | 0x80)
            remainingValue >>= 7
        }
        append(UInt8(remainingValue))
    }

    fileprivate mutating func appendVarintField(fieldNumber: Int, value: UInt64) {
        appendVarint(UInt64(fieldNumber << 3 | 0))  // wire type 0
        appendVarint(value)
    }

    fileprivate mutating func appendLDelField(fieldNumber: Int, value: Data) {
        appendVarint(UInt64(fieldNumber << 3 | 2))  // wire type 2
        appendVarint(UInt64(value.count))
        append(value)
    }

    fileprivate mutating func appendStringField(fieldNumber: Int, value: String) {
        let bytes = Data(value.utf8)
        appendLDelField(fieldNumber: fieldNumber, value: bytes)
    }
}
