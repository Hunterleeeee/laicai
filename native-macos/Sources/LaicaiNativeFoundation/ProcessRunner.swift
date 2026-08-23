import Darwin
import Foundation

public struct ProcessRunResult: Sendable, Equatable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32
    public let timedOut: Bool

    public var stdoutString: String { Self.utf8String(from: stdout) }
    public var stderrString: String { Self.utf8String(from: stderr) }

    public init(stdout: Data, stderr: Data, exitCode: Int32, timedOut: Bool) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
    }

    private static func utf8String(from data: Data) -> String {
        String(bytes: data, encoding: .utf8)
            ?? "<non-UTF-8 process output: \(data.count) bytes>"
    }
}

/// Runs a child process while draining stdout and stderr concurrently.
/// Waiting before draining can deadlock once either pipe reaches its kernel buffer limit.
public enum ProcessRunner {
    public static func run(
        executableURL: URL,
        arguments: [String] = [],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil,
        standardInput: Data? = nil,
        timeout: TimeInterval? = nil
    ) throws -> ProcessRunResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let inputPipe: Pipe?
        if standardInput != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inputPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            inputPipe = nil
        }

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }
        try process.run()

        let stdout = Locked(Data())
        let stderr = Locked(Data())
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            stdout.withValue { $0 = data }
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderr.withValue { $0 = data }
            drainGroup.leave()
        }

        if let standardInput, let inputPipe {
            DispatchQueue.global(qos: .utility).async {
                inputPipe.fileHandleForWriting.write(standardInput)
                try? inputPipe.fileHandleForWriting.close()
            }
        }

        let waitResult: DispatchTimeoutResult
        if let timeout {
            waitResult = termination.wait(timeout: .now() + max(0, timeout))
        } else {
            // A child that ignores pipes/signals must not deadlock the main
            // actor forever. Keep a generous ceiling even for "no timeout".
            waitResult = termination.wait(timeout: .now() + 600)
        }

        let timedOut = waitResult == .timedOut && process.isRunning
        if timedOut {
            process.terminate()
            if termination.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = termination.wait(timeout: .now() + 2)
            }
        }

        drainGroup.wait()
        process.terminationHandler = nil
        return ProcessRunResult(
            stdout: stdout.withValue { $0 },
            stderr: stderr.withValue { $0 },
            exitCode: process.terminationStatus,
            timedOut: timedOut
        )
    }

    public static func runAsync(
        executableURL: URL,
        arguments: [String] = [],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil,
        standardInput: Data? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> ProcessRunResult {
        try await Task.detached(priority: .utility) {
            try run(
                executableURL: executableURL,
                arguments: arguments,
                currentDirectoryURL: currentDirectoryURL,
                environment: environment,
                standardInput: standardInput,
                timeout: timeout
            )
        }.value
    }
}
