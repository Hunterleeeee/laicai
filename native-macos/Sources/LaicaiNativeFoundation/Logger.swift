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

public enum NetworkDefaults {
    public static let quickProbe: TimeInterval = 3
    public static let shortRequest: TimeInterval = 12
    public static let modelList: TimeInterval = 15
    public static let webFetch: TimeInterval = 18
    public static let imageRequest: TimeInterval = 180
    public static let localChat: TimeInterval = 45
    public static let remoteChat: TimeInterval = 120

    public static var ephemeralSession: URLSession {
        URLSession(configuration: .ephemeral)
    }

    public static var webSocketSession: URLSession {
        URLSession(configuration: .default)
    }
}
