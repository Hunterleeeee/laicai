import Foundation
import LaicaiNativeDomain

// MARK: - Sandbox Configuration

public struct SandboxConfig: Codable, Sendable {
    public var mode: SandboxMode
    public var dockerImage: String
    public var mountWorkspace: Bool
    public var networkEnabled: Bool
    public var timeoutSeconds: Int
    public var memoryLimitMB: Int

    public enum SandboxMode: String, Codable, Sendable, CaseIterable {
        case auto = "auto"
        case none = "none"
        case macSandbox = "macos"
        case docker = "docker"

        public var title: String {
            switch self {
            case .auto: return "自动（优先 Docker）"
            case .none: return "无隔离"
            case .macSandbox: return "macOS 沙箱"
            case .docker: return "Docker 容器"
            }
        }
    }

    public static let `default` = SandboxConfig(
        mode: .none,
        dockerImage: "ubuntu:22.04",
        mountWorkspace: true,
        networkEnabled: false,
        timeoutSeconds: 60,
        memoryLimitMB: 512
    )

    public init(
        mode: SandboxMode = .none,
        dockerImage: String = "ubuntu:22.04",
        mountWorkspace: Bool = true,
        networkEnabled: Bool = false,
        timeoutSeconds: Int = 60,
        memoryLimitMB: Int = 512
    ) {
        self.mode = mode
        self.dockerImage = dockerImage
        self.mountWorkspace = mountWorkspace
        self.networkEnabled = networkEnabled
        self.timeoutSeconds = timeoutSeconds
        self.memoryLimitMB = memoryLimitMB
    }
}

public struct SandboxCommandResult: Sendable {
    public let output: String
    public let error: String
    public let exitCode: Int32
}

// MARK: - Sandbox Executor

public struct SandboxExecutor: Sendable {

    /// Execute a shell command within the configured sandbox.
    /// Returns stdout, stderr, and exit code.
    public static func execute(
        command: String,
        workspaceRoot: String,
        config: SandboxConfig
    ) async throws -> SandboxCommandResult {
        switch config.mode {
        case .auto:
            if isDockerAvailable() {
                return try await executeDocker(command: command, workspaceRoot: workspaceRoot, config: config)
            }
            let result = try await executeNative(command: command, workspaceRoot: workspaceRoot, timeout: config.timeoutSeconds)
            let warning = "沙箱自动模式警告：Docker 不可用，已回退到原生执行（无隔离）。"
            let error = result.error.isEmpty ? warning : warning + "\n" + result.error
            return SandboxCommandResult(output: result.output, error: error, exitCode: result.exitCode)
        case .none:
            return try await executeNative(command: command, workspaceRoot: workspaceRoot, timeout: config.timeoutSeconds)
        case .macSandbox:
            return try await executeMacSandbox(command: command, workspaceRoot: workspaceRoot, config: config)
        case .docker:
            return try await executeDocker(command: command, workspaceRoot: workspaceRoot, config: config)
        }
    }

    /// Check if Docker is available on the system
    public static func isDockerAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker", "info"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Native (no sandbox)

    private static func executeNative(command: String, workspaceRoot: String, timeout: Int) async throws -> SandboxCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        if !workspaceRoot.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: workspaceRoot)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let didTimeout = await waitForExit(process, timeoutSeconds: timeout)
        if didTimeout {
            process.terminate()
            process.waitUntilExit()
        }

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outData, encoding: .utf8) ?? ""
        let errOutput = String(data: errData, encoding: .utf8) ?? ""

        return SandboxCommandResult(output: output, error: errOutput, exitCode: process.terminationStatus)
    }

    private static func waitForExit(_ process: Process, timeoutSeconds: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let finished = Locked(false)
            process.terminationHandler = { _ in
                let shouldResume = finished.withValue { value in
                    guard !value else { return false }
                    value = true
                    return true
                }
                if shouldResume {
                    continuation.resume(returning: false)
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                let shouldResume = finished.withValue { value in
                    guard !value else { return false }
                    value = true
                    return true
                }
                if shouldResume {
                    continuation.resume(returning: true)
                }
            }
        }
    }

    // MARK: - macOS sandbox-exec

    private static func executeMacSandbox(
        command: String,
        workspaceRoot: String,
        config: SandboxConfig
    ) async throws -> SandboxCommandResult {
        let runtimeRoot = NSTemporaryDirectory().appending("laicai_sandbox_runtime_\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: runtimeRoot) }

        // Build sandbox profile
        var profile = """
        (version 1)
        (deny default)
        (allow process-exec)
        (allow process-fork)
        (allow file-read* (subpath "/usr"))
        (allow file-read* (subpath "/bin"))
        (allow file-read* (subpath "/sbin"))
        (allow file-read* (subpath "/opt/homebrew"))
        (allow file-read* (subpath "/dev"))
        (allow file-write* (subpath "/dev/null"))
        (allow file-read* (subpath "\(runtimeRoot)"))
        (allow file-write* (subpath "\(runtimeRoot)"))
        (allow sysctl-read)
        (allow mach-lookup)
        """

        if !workspaceRoot.isEmpty {
            profile += "\n(allow file-read* (subpath \"\(workspaceRoot)\"))"
            if config.mountWorkspace {
                profile += "\n(allow file-write* (subpath \"\(workspaceRoot)\"))"
            }
        }

        if config.networkEnabled {
            profile += "\n(allow network-outbound)"
            profile += "\n(allow network-inbound)"
        }

        // Write profile to temp file
        let profilePath = NSTemporaryDirectory().appending("laicai_sandbox_\(UUID().uuidString).sb")
        try profile.write(toFile: profilePath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: profilePath) }

        let sandboxedCommand = "sandbox-exec -f \(profilePath) /bin/zsh -lc '\(command.replacingOccurrences(of: "'", with: "'\\''"))'"
        return try await executeNative(command: sandboxedCommand, workspaceRoot: workspaceRoot, timeout: config.timeoutSeconds)
    }

    // MARK: - Docker execution

    private static func executeDocker(
        command: String,
        workspaceRoot: String,
        config: SandboxConfig
    ) async throws -> SandboxCommandResult {
        var dockerArgs = ["docker", "run", "--rm"]

        // Memory limit
        dockerArgs += ["-m", "\(config.memoryLimitMB)m"]

        // Network
        if !config.networkEnabled {
            dockerArgs += ["--network", "none"]
        }

        // Mount workspace
        if config.mountWorkspace && !workspaceRoot.isEmpty {
            dockerArgs += ["-v", "\(workspaceRoot):/workspace", "-w", "/workspace"]
        }

        // Timeout via --stop-timeout
        dockerArgs += ["--stop-timeout", "\(config.timeoutSeconds)"]

        // Image and command
        dockerArgs += [config.dockerImage, "/bin/sh", "-c", command]

        let fullCommand = dockerArgs.map { arg in
            arg.contains(" ") ? "'\(arg)'" : arg
        }.joined(separator: " ")

        return try await executeNative(command: fullCommand, workspaceRoot: "", timeout: config.timeoutSeconds + 10)
    }
}
