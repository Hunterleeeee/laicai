import Foundation
import LaicaiNativeDomain

extension AppStore {
    /// Undo the last auto-checkpoint by running `git reset HEAD~1`.
    /// This reverts all file changes made since the last checkpoint while keeping them staged.
    public func undoLastCheckpoint() {
        let root = state.settings.workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            notify("未设置工作区，无法回滚")
            return
        }
        guard FileManager.default.fileExists(atPath: root + "/.git") else {
            notify("工作区不是 Git 仓库，无法回滚")
            return
        }

        guard
            let logResult = try? ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["git", "log", "-1", "--format=%s"],
                currentDirectoryURL: URL(fileURLWithPath: root),
                timeout: 10
            ), logResult.exitCode == 0, !logResult.timedOut
        else {
            notify("无法读取最近一次 Git 提交")
            return
        }
        let lastMessage = logResult.stdoutString

        guard lastMessage.contains("来财自动检查点") else {
            notify("最近一次提交不是来财检查点")
            return
        }

        guard
            let resetResult = try? ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["git", "reset", "HEAD~1"],
                currentDirectoryURL: URL(fileURLWithPath: root),
                timeout: 30
            )
        else {
            notify("回滚命令无法启动")
            return
        }
        let resetOutput = resetResult.stdoutString + resetResult.stderrString

        if resetResult.exitCode == 0, !resetResult.timedOut {
            notify("已回滚到最近检查点（变更保留在工作区）", style: .success)
            AuditLog.shared.record(tool: "git.reset", input: "undo checkpoint", output: resetOutput.prefix(200).description, success: true)
        } else {
            notify("回滚失败：\(resetOutput.prefix(100))")
            AuditLog.shared.record(tool: "git.reset", input: "undo checkpoint", output: resetOutput.prefix(200).description, success: false)
        }
    }
}
