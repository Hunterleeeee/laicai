import Foundation

public enum LaicaiLog {
    public static func info(_ message: String) {
        write("INFO", message)
    }

    public static func warning(_ message: String) {
        write("WARN", message)
    }

    public static func error(_ message: String) {
        write("ERROR", message)
    }

    private static func write(_ level: String, _ message: String) {
        FileHandle.standardError.write(Data("[Laicai] [\(level)] \(message)\n".utf8))
    }
}

// MARK: - Agent Logger (Structured per-iteration logging)

public struct AgentIterationLog: Codable, Sendable {
    public let timestamp: Date
    public let taskID: String
    public let iteration: Int
    public let phase: String
    public let intent: String
    public let connectorName: String
    public let toolCalls: [ToolCallLog]
    public let tokenUsage: TokenUsageLog?
    public let error: String?
    public let durationSeconds: TimeInterval
    public let messageCount: Int
    public let stepCount: Int

    public struct ToolCallLog: Codable, Sendable {
        public let toolName: String
        public let success: Bool
        public let durationSeconds: TimeInterval
        public let errorDetail: String?
    }

    public struct TokenUsageLog: Codable, Sendable {
        public let inputTokens: Int
        public let outputTokens: Int
        public let tokensPerSecond: Double
    }
}

public final class AgentLogger: Sendable {
    public static let shared = AgentLogger()

    private let logsDirectory: URL
    private let encoder: JSONEncoder

    private init() {
        logsDirectory = LaicaiStoragePaths.ensureDirectory(
            LaicaiStoragePaths.appDirectory.appendingPathComponent("AgentLogs", isDirectory: true)
        )

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    public func logIteration(_ log: AgentIterationLog) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: log.timestamp)

        let fileURL = logsDirectory.appendingPathComponent("\(dateString).jsonl")

        guard let data = try? encoder.encode(log),
            let line = String(data: data, encoding: .utf8)
        else { return }

        let entry = line + "\n"

        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(Data(entry.utf8))
                handle.closeFile()
            }
        } else {
            try? entry.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    public func logs(for date: Date) -> [AgentIterationLog] {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: date)

        let fileURL = logsDirectory.appendingPathComponent("\(dateString).jsonl")

        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return content.components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .compactMap { line in
                try? decoder.decode(AgentIterationLog.self, from: Data(line.utf8))
            }
    }

    public func recentLogs(limit: Int = 50) -> [AgentIterationLog] {
        let calendar = Calendar.current
        let today = Date()

        var allLogs: [AgentIterationLog] = []
        for dayOffset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { break }
            allLogs.append(contentsOf: logs(for: date))
        }

        return Array(allLogs.suffix(limit))
    }
}

public enum NetworkDefaults {
    public static let quickProbe: TimeInterval = 3
    public static let shortRequest: TimeInterval = 12
    public static let modelList: TimeInterval = 15
    public static let webFetch: TimeInterval = 18
    public static let imageRequest: TimeInterval = 180
    public static let localChat: TimeInterval = 45
    public static let remoteChat: TimeInterval = 120

    public static let ephemeralSession = URLSession(configuration: .ephemeral)

    public static let imageSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = imageRequest
        configuration.timeoutIntervalForResource = imageRequest + 30
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    public static let webSocketSession = URLSession(configuration: .default)
}
