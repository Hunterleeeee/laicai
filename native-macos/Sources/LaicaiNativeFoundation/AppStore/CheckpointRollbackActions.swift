import Foundation
import LaicaiNativeDomain

extension AppStore {
    /// Undo the last auto-checkpoint by running `git reset HEAD~1`.
    /// This reverts all file changes made since the last checkpoint while keeping them staged.
    public func undoLastCheckpoint() {
        let root = state.settings.workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            ToastCenter.shared.warn("未设置工作区，无法回滚")
            return
        }
        guard FileManager.default.fileExists(atPath: root + "/.git") else {
            ToastCenter.shared.warn("工作区不是 Git 仓库，无法回滚")
            return
        }

        let logProcess = Process()
        logProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        logProcess.currentDirectoryURL = URL(fileURLWithPath: root)
        logProcess.arguments = ["git", "log", "-1", "--format=%s"]
        let logPipe = Pipe()
        logProcess.standardOutput = logPipe
        logProcess.standardError = Pipe()
        try? logProcess.run()
        logProcess.waitUntilExit()
        let logData = logPipe.fileHandleForReading.readDataToEndOfFile()
        let lastMessage = String(data: logData, encoding: .utf8) ?? ""

        guard lastMessage.contains("来财自动检查点") else {
            ToastCenter.shared.warn("最近一次提交不是来财检查点")
            return
        }

        let resetProcess = Process()
        resetProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        resetProcess.currentDirectoryURL = URL(fileURLWithPath: root)
        resetProcess.arguments = ["git", "reset", "HEAD~1"]
        let resetPipe = Pipe()
        resetProcess.standardOutput = resetPipe
        resetProcess.standardError = resetPipe
        try? resetProcess.run()
        resetProcess.waitUntilExit()
        let resetData = resetPipe.fileHandleForReading.readDataToEndOfFile()
        let resetOutput = String(data: resetData, encoding: .utf8) ?? ""

        if resetProcess.terminationStatus == 0 {
            ToastCenter.shared.success("已回滚到最近检查点（变更保留在工作区）")
            AuditLog.shared.record(tool: "git.reset", input: "undo checkpoint", output: resetOutput.prefix(200).description, success: true)
        } else {
            ToastCenter.shared.warn("回滚失败：\(resetOutput.prefix(100))")
            AuditLog.shared.record(tool: "git.reset", input: "undo checkpoint", output: resetOutput.prefix(200).description, success: false)
        }
    }
}
