import Foundation
import LaicaiNativeDomain

enum LegacyJSONMigration {
    static func applicationSupportDirectory(fileManager: FileManager = .default) -> URL? {
        guard let base = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return nil }
        return base.appendingPathComponent("LaicaiNative", isDirectory: true)
    }

    static func loadSessions(from directory: URL? = applicationSupportDirectory()) -> [ChatSession]? {
        load([ChatSession].self, from: directory?.appendingPathComponent("sessions.json"))
    }

    static func loadConnectorCatalog(from directory: URL? = applicationSupportDirectory()) -> ConnectorCatalog? {
        load(ConnectorCatalog.self, from: directory?.appendingPathComponent("connectors.json"))
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL?) -> T? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
