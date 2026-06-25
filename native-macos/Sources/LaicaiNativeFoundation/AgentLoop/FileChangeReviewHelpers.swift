import Foundation
import LaicaiNativeDomain

@MainActor
extension AgentLoop {
    static func extractHunks(from params: [String: String]) -> [DiffHunk] {
        guard let countStr = params["hunkCount"], let count = Int(countStr), count > 0 else { return [] }
        var hunks: [DiffHunk] = []
        for i in 0..<count {
            let oldText = params["hunk\(i).oldText"] ?? ""
            let newText = params["hunk\(i).newText"] ?? ""
            let summary = params["hunk\(i).summary"] ?? "Hunk \(i + 1)"
            hunks.append(DiffHunk(index: i, oldText: oldText, newText: newText, summary: summary))
        }
        return hunks
    }

    static func fileChangeReviewSteps(
        data: [String: String],
        toolName: String,
        toolParams: [String: String],
        callId: String,
        workspaceRoot: String
    ) -> [TaskStep] {
        var steps: [TaskStep] = []

        if let batchCountString = data["batchCount"], let batchCount = Int(batchCountString) {
            for batchIndex in 0..<batchCount {
                let prefix = "batch\(batchIndex)"
                guard let filePath = data["\(prefix).path"],
                      let oldContent = data["\(prefix).diffOld"],
                      let newContent = data["\(prefix).diffNew"],
                      !newContent.isEmpty else { continue }

                let fullPath = data["\(prefix).fullPath"] ?? resolvedFileChangePath(filePath, workspaceRoot: workspaceRoot)
                let createDirectories = data["\(prefix).createDirectories"] != "false"
                do {
                    try WriteFileTool().performWrite(fullPath: fullPath, content: newContent, createDirectories: createDirectories)
                } catch {
                    // Keep surfacing the attempted diff through the review step.
                }

                var reviewParams = toolParams
                for (key, value) in data where key.hasPrefix(prefix + ".") {
                    reviewParams[String(key.dropFirst(prefix.count + 1))] = value
                }
                reviewParams["batchIndex"] = "\(batchIndex + 1)"
                reviewParams["batchCount"] = "\(batchCount)"

                steps.append(fileChangeReviewStep(
                    text: "已写入文件（可回滚）（\(batchIndex + 1)/\(batchCount)）：\(filePath)",
                    toolName: toolName,
                    toolParams: reviewParams,
                    callId: callId,
                    filePath: filePath,
                    oldContent: oldContent,
                    newContent: newContent
                ))
            }
            return steps
        }

        guard let filePath = data["path"] ?? toolParams["path"],
              let oldContent = data["diffOld"],
              let newContent = data["diffNew"],
              !newContent.isEmpty else { return steps }

        let fullPath = data["fullPath"] ?? resolvedFileChangePath(filePath, workspaceRoot: workspaceRoot)
        let createDirectories = data["createDirectories"] != "false"
        var writeSucceeded = false
        do {
            try WriteFileTool().performWrite(fullPath: fullPath, content: newContent, createDirectories: createDirectories)
            if let written = try? String(contentsOfFile: fullPath, encoding: .utf8),
               !written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                writeSucceeded = true
            }
        } catch {
            // Surface the failure through a tool result step below.
        }

        if !writeSucceeded {
            steps.append(TaskStep(
                kind: .toolResult,
                text: "⚠️ 文件写入验证失败：\(filePath) 写入后为空。请检查工具参数并重试（确保 content 参数包含完整内容）。",
                toolName: toolName,
                toolCallId: callId,
                isFailure: true
            ))
        }

        var reviewParams = toolParams
        for (key, value) in data {
            reviewParams[key] = value
        }
        steps.append(fileChangeReviewStep(
            text: writeSucceeded ? "已写入文件（可回滚）：\(filePath)" : "写入失败（文件为空）：\(filePath)",
            toolName: toolName,
            toolParams: reviewParams,
            callId: callId,
            filePath: filePath,
            oldContent: oldContent,
            newContent: newContent
        ))
        return steps
    }

    private static func fileChangeReviewStep(
        text: String,
        toolName: String,
        toolParams: [String: String],
        callId: String,
        filePath: String,
        oldContent: String,
        newContent: String
    ) -> TaskStep {
        let hunks = extractHunks(from: toolParams)
        return TaskStep(
            kind: .reviewRequest,
            text: text,
            toolName: toolName,
            toolParams: toolParams,
            toolCallId: callId,
            isCollapsible: false,
            isCollapsed: false,
            diffFilePath: filePath,
            diffOldContent: oldContent,
            diffNewContent: newContent,
            approved: true,
            diffHunks: hunks.isEmpty ? nil : hunks
        )
    }

    private static func resolvedFileChangePath(_ path: String, workspaceRoot: String) -> String {
        path.hasPrefix("/") ? path : (workspaceRoot as NSString).appendingPathComponent(path)
    }
}
