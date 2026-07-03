import Foundation
import LaicaiNativeDomain

// MARK: - 跨设备会话接力 (Session Teleport)

/// Portable session bundle for cross-device transfer
public struct TeleportBundle: Codable, Sendable {
    public static let formatVersion = 1
    public var version: Int = TeleportBundle.formatVersion
    public var exportedAt: Date
    public var deviceName: String
    public var threads: [Thread]
    public var connectorProfiles: [ConnectorProfileSnapshot]
    public var settings: SettingsSnapshot
    public var skills: [SkillDefinition]?

    public init(
        threads: [Thread],
        connectorProfiles: [ConnectorProfileSnapshot],
        settings: SettingsSnapshot,
        skills: [SkillDefinition]? = nil
    ) {
        self.exportedAt = Date()
        self.deviceName = Host.current().localizedName ?? "Unknown"
        self.threads = threads
        self.connectorProfiles = connectorProfiles
        self.settings = settings
        self.skills = skills
    }
}

/// Minimal connector info for teleport (no secrets)
public struct ConnectorProfileSnapshot: Codable, Sendable {
    public var name: String
    public var kind: String
    public var endpoint: String
    public var modelName: String
    // Note: API key is NOT exported for security

    public init(from connector: ConnectorProfile) {
        self.name = connector.name
        self.kind = connector.kind
        self.endpoint = connector.endpoint
        self.modelName = connector.modelName
    }
}

/// Minimal settings for teleport
public struct SettingsSnapshot: Codable, Sendable {
    public var workspacePath: String
    public var contextMode: String
    public var compactComposer: Bool

    public init(workspacePath: String, contextMode: String, compactComposer: Bool) {
        self.workspacePath = workspacePath
        self.contextMode = contextMode
        self.compactComposer = compactComposer
    }
}

// MARK: - Teleport Engine

@MainActor
public final class SessionTeleport: ObservableObject {
    public static let shared = SessionTeleport()
    private init() {}

    public enum TeleportError: LocalizedError {
        case noThreads
        case encodingFailed
        case decodingFailed(String)
        case versionMismatch(Int)
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noThreads: return "没有可导出的会话"
            case .encodingFailed: return "序列化失败"
            case .decodingFailed(let details): return "反序列化失败：\(details)"
            case .versionMismatch(let version): return "格式版本不兼容：\(version)"
            case .writeFailed(let path): return "写入失败：\(path)"
            }
        }
    }

    /// Export threads to a .laicai-teleport file
    public func exportBundle(
        threads: [Thread],
        connectors: [ConnectorProfile],
        settings: AppSettings,
        skills: [SkillDefinition] = [],
        to url: URL
    ) throws {
        guard !threads.isEmpty else { throw TeleportError.noThreads }

        let snapshots = connectors.map { ConnectorProfileSnapshot(from: $0) }
        let settingsSnap = SettingsSnapshot(
            workspacePath: settings.workspacePath,
            contextMode: settings.contextMode.rawValue,
            compactComposer: settings.compactComposer
        )

        let bundle = TeleportBundle(
            threads: threads,
            connectorProfiles: snapshots,
            settings: settingsSnap,
            skills: skills.isEmpty ? nil : skills
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(bundle) else {
            throw TeleportError.encodingFailed
        }

        // Compress with zlib
        let compressed = (try? (data as NSData).compressed(using: .zlib)) as Data? ?? data

        do {
            try compressed.write(to: url, options: .atomic)
        } catch {
            throw TeleportError.writeFailed(url.path)
        }
    }

    /// Import a .laicai-teleport file
    public func importBundle(from url: URL) throws -> TeleportBundle {
        let rawData = try Data(contentsOf: url)

        // Try decompress first, fall back to raw
        let data: Data
        if let decompressed = (try? (rawData as NSData).decompressed(using: .zlib)) as Data? {
            data = decompressed
        } else {
            data = rawData
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let bundle = try decoder.decode(TeleportBundle.self, from: data)
            guard bundle.version == TeleportBundle.formatVersion else {
                throw TeleportError.versionMismatch(bundle.version)
            }
            return bundle
        } catch let error as TeleportError {
            throw error
        } catch {
            throw TeleportError.decodingFailed(error.localizedDescription)
        }
    }

    /// Merge imported bundle into current state
    public func mergeBundle(
        _ bundle: TeleportBundle,
        into threads: inout [Thread],
        connectors: inout [ConnectorProfile]
    ) -> MergeResult {
        var imported = 0
        var skipped = 0
        var connectorHints: [String] = []

        // Merge threads (skip duplicates by ID)
        let existingIDs = Set(threads.map(\.id))
        for thread in bundle.threads {
            if existingIDs.contains(thread.id) {
                skipped += 1
            } else {
                threads.insert(thread, at: 0)
                imported += 1
            }
        }

        // Suggest connectors (don't auto-add since they need API keys)
        let existingEndpoints = Set(connectors.map { $0.endpoint.lowercased() })
        for snap in bundle.connectorProfiles where !existingEndpoints.contains(snap.endpoint.lowercased()) {
            connectorHints.append("\(snap.name) (\(snap.endpoint))")
        }

        return MergeResult(
            importedThreads: imported,
            skippedThreads: skipped,
            connectorHints: connectorHints,
            sourceDevice: bundle.deviceName,
            exportedAt: bundle.exportedAt
        )
    }

    public struct MergeResult: Sendable {
        public var importedThreads: Int
        public var skippedThreads: Int
        public var connectorHints: [String]
        public var sourceDevice: String
        public var exportedAt: Date

        public var summary: String {
            var parts: [String] = []
            parts.append("从「\(sourceDevice)」导入 \(importedThreads) 个会话")
            if skippedThreads > 0 { parts.append("跳过 \(skippedThreads) 个重复") }
            if !connectorHints.isEmpty {
                parts.append("建议添加连接器：\(connectorHints.joined(separator: "、"))")
            }
            return parts.joined(separator: "；")
        }
    }

    /// Default file extension
    public static let fileExtension = "laicai-teleport"

    /// Export path suggestion
    public static func suggestedExportURL(workspaceName: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let timestamp = formatter.string(from: Date())
        let name = workspaceName.isEmpty ? "laicai" : workspaceName
        let filename = "\(name)-\(timestamp).\(fileExtension)"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return desktop.appendingPathComponent(filename)
    }
}
