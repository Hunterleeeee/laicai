import Foundation
import LaicaiNativeDomain

@MainActor
extension AgentLoop {
    struct ShellStreamingRequest {
        let argumentsJSON: String
        let context: TaskContext
        let threadID: UUID
        let resultStepID: UUID
        let callID: String
        let command: String
    }

    static func executeShellStreamingViaNotification(_ request: ShellStreamingRequest) async -> ToolResult {
        struct Params: Codable {
            var command: String
            var timeout: Int?
        }
        let params: Params
        do {
            let data = request.argumentsJSON.data(using: .utf8) ?? Data()
            params = try JSONDecoder().decode(Params.self, from: data)
        } catch {
            return ToolResult(output: "参数解析失败：\(error.localizedDescription)", success: false, error: "invalid_params")
        }

        let cmd = params.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else {
            return ToolResult(
                output: "shell.exec 缺少 command 参数。不要重试空命令；请根据原始用户目标、已读文件和最近失败，构造一个具体命令，或改用更合适的工具（workspace.index/code.search/file.read/document.transform）。",
                success: false,
                error: "missing_command"
            )
        }
        let policySnapshot = SecurityManager.shared.policySnapshot
        if let securityError = shellSecurityCheck(command: cmd, policy: policySnapshot) {
            return ToolResult(output: securityError, success: false, error: "security_denied")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", cmd]
        if !request.context.workspaceRoot.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: request.context.workspaceRoot)
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        return await withCheckedContinuation { continuation in
            let streamState = AgentShellStreamState()

            @Sendable func postUpdate(_ text: String, isFinal: Bool = false, isFailure: Bool = false) {
                NotificationCenter.default.post(
                    name: .shellStreamUpdate,
                    object: nil,
                    userInfo: [
                        "threadID": request.threadID,
                        "stepID": request.resultStepID,
                        "callID": request.callID,
                        "command": cmd,
                        "text": text.isEmpty ? "命令运行中…" : text,
                        "isFinal": isFinal,
                        "isFailure": isFailure
                    ]
                )
            }

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                let snapshot = streamState.append(chunk)
                postUpdate(snapshot)
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                let snapshot = streamState.append(chunk)
                postUpdate(snapshot)
            }

            do {
                try process.run()
                postUpdate("$ \(cmd)\n")
            } catch {
                continuation.resume(returning: ToolResult(output: "无法启动命令：\(error.localizedDescription)", success: false, error: "launch_failed"))
                return
            }

            let requestedTimeout = params.timeout.map(TimeInterval.init)
            let timeout = min(max(requestedTimeout ?? ValidationEngine.timeoutSeconds(for: "shell.exec"), 1), 300)
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                if process.isRunning { process.terminate() }
            }
            timer.resume()

            process.terminationHandler = { process in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                timer.cancel()
                let (captured, shouldResume) = streamState.finish()
                guard shouldResume else { return }
                let exitCode = process.terminationStatus
                let body = captured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "命令无输出" : captured
                let finalText = exitCode == 0 ? body : "命令失败（退出码 \(exitCode)）：\n\(body)"
                postUpdate(finalText, isFinal: true, isFailure: exitCode != 0)
                continuation.resume(returning: ToolResult(
                    output: finalText,
                    data: ["exitCode": "\(exitCode)", "streamed": "true"],
                    success: exitCode == 0,
                    error: exitCode == 0 ? nil : "exit_\(exitCode)"
                ))
            }
        }
    }
}
