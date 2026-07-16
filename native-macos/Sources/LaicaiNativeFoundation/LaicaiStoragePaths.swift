import Foundation

/// Centralized storage locations so tests never touch a user's real Laicai data.
public enum LaicaiStoragePaths {
    public static let rootOverrideEnvironmentKey = "LAICAI_APPLICATION_SUPPORT_ROOT"

    private static let isolatedTestRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("LaicaiTests", isDirectory: true)
        .appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)

    private static let isolatedDefaultsSuiteName =
        "com.laicai.native.tests.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)"

    public static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || Bundle.main.bundlePath.hasSuffix(".xctest")
            || NSClassFromString("XCTestCase") != nil
    }

    /// Root equivalent to the user's Application Support directory.
    public static var supportRoot: URL {
        if let override = ProcessInfo.processInfo.environment[rootOverrideEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if isRunningTests {
            return isolatedTestRoot
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    public static var appDirectory: URL {
        supportRoot.appendingPathComponent("Laicai", isDirectory: true)
    }

    public static var legacyAppDirectory: URL {
        supportRoot.appendingPathComponent("LaicaiNative", isDirectory: true)
    }

    public static var defaults: UserDefaults {
        guard isRunningTests else { return .standard }
        return UserDefaults(suiteName: isolatedDefaultsSuiteName) ?? .standard
    }

    public static var keychainService: String {
        guard isRunningTests else { return "com.laicai.native.secrets" }
        return "com.laicai.native.secrets.tests.\(ProcessInfo.processInfo.processIdentifier)"
    }

    @discardableResult
    public static func ensureDirectory(_ directory: URL) -> URL {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    /// Preserves the existing convention where an injected path is a support root,
    /// not the final `Laicai` directory itself.
    public static func appDirectory(basePath: String?) -> URL {
        guard let basePath else { return ensureDirectory(appDirectory) }
        return ensureDirectory(
            URL(fileURLWithPath: basePath, isDirectory: true)
                .appendingPathComponent("Laicai", isDirectory: true)
        )
    }
}
