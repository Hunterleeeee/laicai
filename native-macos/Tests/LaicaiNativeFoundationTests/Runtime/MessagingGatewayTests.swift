import Darwin
import Foundation
import LaicaiNativeDomain
import XCTest

@testable import LaicaiNativeFoundation

final class MessagingGatewayTests: LaicaiNativeFoundationTestCase {
    func testUnavailableChannelsExposeCapabilityReason() {
        XCTAssertFalse(ChannelType.wecom.isAvailable)
        XCTAssertFalse(ChannelType.slack.isAvailable)
        XCTAssertEqual(ChannelType.wecom.capability, .unavailable)
        XCTAssertFalse(ChannelType.wecom.availabilityDescription.isEmpty)
        XCTAssertTrue(ChannelType.telegram.isAvailable)
        XCTAssertEqual(ChannelType.webhook.capability, .inboundWebhook)
    }

    func testWebhookParserRejectsInvalidJSONAndEmptyText() {
        XCTAssertThrowsError(
            try GatewayHTTPServer.parseWebhookRequest("POST /webhook HTTP/1.1\r\n\r\nnot-json")
        )
        XCTAssertThrowsError(
            try GatewayHTTPServer.parseWebhookRequest("POST /webhook HTTP/1.1\r\n\r\n{\"text\":\"  \"}")
        )
    }

    func testWebhookParserBuildsValidMessage() throws {
        let message = try GatewayHTTPServer.parseWebhookRequest(
            "POST /webhook HTTP/1.1\r\n\r\n{\"text\":\" hello \",\"sender\":\"user-1\",\"channel\":\"telegram\"}"
        )
        XCTAssertEqual(message.text, "hello")
        XCTAssertEqual(message.sender, "user-1")
        XCTAssertEqual(message.channel, .telegram)
    }

    @MainActor
    func testGatewayReportsBindFailureAndDoesNotClaimRunning() throws {
        let port = try availableLoopbackPort()
        let firstRoot = try makeTemporaryWorkspace()
        let secondRoot = try makeTemporaryWorkspace()
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }
        let first = MessagingGateway()
        let second = MessagingGateway()
        XCTAssertTrue(first.start(workspaceRoot: firstRoot.path, port: port))
        defer { first.stop() }

        XCTAssertFalse(second.start(workspaceRoot: secondRoot.path, port: port))
        XCTAssertFalse(second.isRunning)
        XCTAssertNotNil(second.gatewayError)
    }

    func testInvalidWebhookReturnsHTTP400() async throws {
        let port = try availableLoopbackPort()
        let server = GatewayHTTPServer(port: port) { _ in
            XCTFail("Invalid webhook must not reach the handler")
        }
        guard case .success = server.start() else {
            return XCTFail("Unable to start test webhook server")
        }
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/webhook")!)
        request.httpMethod = "POST"
        request.httpBody = Data("not-json".utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
    }

    @MainActor
    func testMessagingSecretsRotateAndAreDeletedWithoutPlaintextPersistence() throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let gateway = MessagingGateway()
        XCTAssertTrue(gateway.prepare(workspaceRoot: workspace.path))
        let channelID = UUID()
        let first = ChannelConfig(
            id: channelID,
            type: .telegram,
            enabled: false,
            config: ["bot_token": "first-secret"]
        )
        XCTAssertTrue(gateway.addChannel(first))

        let path = workspace.appendingPathComponent(".laicai/messaging_channels.json")
        let firstData = try Data(contentsOf: path)
        let firstText = try XCTUnwrap(String(data: firstData, encoding: .utf8))
        XCTAssertFalse(firstText.contains("first-secret"))
        let firstStored = try XCTUnwrap(JSONDecoder().decode([ChannelConfig].self, from: firstData).first)
        let firstReference = try XCTUnwrap(firstStored.config["bot_token"])
        XCTAssertTrue(SecretStore.isReference(firstReference))
        XCTAssertEqual(SecretStore.resolve(firstReference), "first-secret")

        var second = first
        second.config["bot_token"] = "second-secret"
        XCTAssertTrue(gateway.updateChannel(second))
        XCTAssertEqual(SecretStore.resolve(firstReference), "")

        let secondData = try Data(contentsOf: path)
        let secondStored = try XCTUnwrap(JSONDecoder().decode([ChannelConfig].self, from: secondData).first)
        let secondReference = try XCTUnwrap(secondStored.config["bot_token"])
        XCTAssertEqual(SecretStore.resolve(secondReference), "second-secret")

        XCTAssertTrue(gateway.removeChannel(id: channelID))
        XCTAssertEqual(SecretStore.resolve(secondReference), "")
    }

    func testTelegramConnectValidatesTokenBeforeMarkingConnected() async throws {
        let session = makeStubbedSession(body: Data(#"{"ok":false}"#.utf8), statusCode: 401)
        let channel = TelegramChannel(
            config: ChannelConfig(type: .telegram, config: ["bot_token": "invalid"]),
            session: session
        )

        do {
            try await channel.connect()
            XCTFail("Invalid Telegram token should fail")
        } catch {
            XCTAssertFalse(channel.isConnected)
            XCTAssertTrue(error.localizedDescription.contains("验证失败"))
        }
    }

    private func availableLoopbackPort() throws -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(.EIO) }
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard nameResult == 0 else { throw POSIXError(.EIO) }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
