import Foundation
import LaicaiNativeDomain

public enum NativeStoragePaths {
    public static func applicationSupportDirectory(fileManager: FileManager = .default) throws -> URL {
        let baseDirectory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = baseDirectory.appendingPathComponent("LaicaiNative", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory
    }

    public static func sessionsURL(fileManager: FileManager = .default) throws -> URL {
        try applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("sessions.json", isDirectory: false)
    }

    public static func connectorsURL(fileManager: FileManager = .default) throws -> URL {
        try applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("connectors.json", isDirectory: false)
    }
}

public struct JSONSessionRepository: SessionRepository {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileURL: URL? = nil,
        encoder: JSONEncoder = JSONSessionRepository.makeEncoder(),
        decoder: JSONDecoder = JSONSessionRepository.makeDecoder()
    ) {
        self.fileURL = fileURL ?? (try? NativeStoragePaths.sessionsURL()) ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("laicai-native-sessions.json")
        self.encoder = encoder
        self.decoder = decoder
    }

    public func loadSessions() throws -> [ChatSession]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([ChatSession].self, from: data)
    }

    public func saveSessions(_ sessions: [ChatSession]) throws {
        let data = try encoder.encode(sessions)
        try data.write(to: fileURL, options: [.atomic])
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public struct JSONConnectorRepository: ConnectorRepository {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileURL: URL? = nil,
        encoder: JSONEncoder = JSONSessionRepository.makeEncoder(),
        decoder: JSONDecoder = JSONSessionRepository.makeDecoder()
    ) {
        self.fileURL = fileURL ?? (try? NativeStoragePaths.connectorsURL()) ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("laicai-native-connectors.json")
        self.encoder = encoder
        self.decoder = decoder
    }

    public func loadConnectorCatalog() throws -> ConnectorCatalog? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(ConnectorCatalog.self, from: data)
    }

    public func saveConnectors(_ connectors: [ConnectorProfile], activeConnectorID: UUID?) throws {
        let catalog = ConnectorCatalog(connectors: connectors, activeConnectorID: activeConnectorID)
        let data = try encoder.encode(catalog)
        try data.write(to: fileURL, options: [.atomicWrite])
    }
}
