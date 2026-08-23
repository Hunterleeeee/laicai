import Foundation
import LaicaiNativeDomain

// MARK: - Gateway HTTP Server (Webhook receiver)

public final class GatewayHTTPServer: Sendable {
    private let port: Int
    private let handler: @Sendable (IncomingMessage) async -> Void
    private struct State {
        var serverSocket: Int32 = -1
        var listenTask: Task<Void, Never>?
    }
    private let state = Locked(State())

    init(port: Int, handler: @escaping @Sendable (IncomingMessage) async -> Void) {
        self.port = port
        self.handler = handler
    }

    func start() -> Result<Void, GatewayError> {
        if state.withValue({ $0.serverSocket >= 0 || $0.listenTask != nil }) {
            return .success(())
        }
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            return .failure(.connectionFailed("无法创建 webhook socket：\(Self.systemError())"))
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(socketFD)
            return .failure(.connectionFailed("端口 \(port) 绑定失败：\(Self.systemError())"))
        }

        guard listen(socketFD, 16) == 0 else {
            close(socketFD)
            return .failure(.connectionFailed("端口 \(port) 监听失败：\(Self.systemError())"))
        }
        state.withValue { $0.serverSocket = socketFD }

        let task = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let currentSocket = self.state.withValue { $0.serverSocket }
                guard currentSocket >= 0 else { break }
                var clientAddr = sockaddr_in()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientSocket = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        accept(currentSocket, $0, &clientAddrLen)
                    }
                }
                guard clientSocket >= 0 else {
                    if Task.isCancelled { break }
                    continue
                }

                Task.detached { [weak self] in
                    await self?.handleConnection(clientSocket)
                }
            }
        }
        state.withValue { $0.listenTask = task }
        return .success(())
    }

    func stop() {
        let snapshot = state.withValue { state in
            let snapshot = (state.listenTask, state.serverSocket)
            state.listenTask = nil
            state.serverSocket = -1
            return snapshot
        }
        snapshot.0?.cancel()
        if snapshot.1 >= 0 {
            close(snapshot.1)
        }
    }

    private func handleConnection(_ socket: Int32) async {
        defer { close(socket) }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let bytesRead = recv(socket, &buffer, buffer.count, 0)
        guard bytesRead > 0, bytesRead <= buffer.count else { return }

        let requestStr = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""

        // Route: POST /webhook or /message — generic webhook
        // Note: Feishu now uses WebSocket long connection, no webhook needed
        let isGenericWebhook = requestStr.hasPrefix("POST /webhook") || requestStr.hasPrefix("POST /message")

        guard isGenericWebhook else {
            Self.sendResponse(socket: socket, status: 404, reason: "Not Found", body: "")
            return
        }

        do {
            let message = try Self.parseWebhookRequest(requestStr)
            await handler(message)
            Self.sendResponse(
                socket: socket,
                status: 200,
                reason: "OK",
                body: #"{"ok":true}"#
            )
        } catch {
            let body = #"{"ok":false,"error":"invalid_request"}"#
            Self.sendResponse(socket: socket, status: 400, reason: "Bad Request", body: body)
        }
    }

    static func parseWebhookRequest(_ request: String) throws -> IncomingMessage {
        guard request.utf8.count <= 64 * 1024 else {
            throw GatewayError.invalidRequest("HTTP 请求过大")
        }
        guard let bodyStart = request.range(of: "\r\n\r\n") else {
            throw GatewayError.invalidRequest("缺少 HTTP body")
        }
        let header = String(request[..<bodyStart.lowerBound])
        let body = String(request[bodyStart.upperBound...])
        if let lengthLine = header.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
            let declaredLength = Int(lengthLine.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? ""),
            declaredLength != body.utf8.count
        {
            throw GatewayError.invalidRequest("HTTP body 长度不完整")
        }
        guard let data = body.data(using: .utf8),
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw GatewayError.invalidRequest("body 不是有效的 JSON 对象")
        }
        let text = (json["text"] as? String ?? json["message"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw GatewayError.invalidRequest("缺少非空 text 或 message")
        }
        let sender = json["sender"] as? String ?? json["from"] as? String ?? "webhook"
        let channel = (json["channel"] as? String).flatMap(ChannelType.init(rawValue:)) ?? .webhook
        var metadata: [String: String] = [:]
        if let channelID = json["channel_id"] as? String, !channelID.isEmpty {
            metadata["channelID"] = channelID
        }
        return IncomingMessage(channel: channel, sender: sender, text: text, metadata: metadata)
    }

    private static func sendResponse(socket: Int32, status: Int, reason: String, body: String) {
        let bodyData = Data(body.utf8)
        let header =
            "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(bodyData)
        response.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            _ = send(socket, baseAddress, response.count, 0)
        }
    }

    private static func systemError() -> String {
        String(cString: strerror(errno))
    }
}

// MARK: - Gateway Error

public enum GatewayError: LocalizedError {
    case missingConfig(String)
    case connectionFailed(String)
    case invalidRequest(String)

    public var errorDescription: String? {
        switch self {
        case .missingConfig(let detail): return "配置缺失：\(detail)"
        case .connectionFailed(let detail): return "连接失败：\(detail)"
        case .invalidRequest(let detail): return "请求无效：\(detail)"
        }
    }
}
