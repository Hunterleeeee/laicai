import Foundation
import LaicaiNativeDomain

@MainActor
extension AgentLoop {
    private struct FileChangeReviewStepRequest {
        let text: String
        let toolName: String
        let toolParams: [String: String]
        let callId: String
        let filePath: String
        let oldContent: String
        let newContent: String
    }

    static func extractHunks(from params: [String: String]) -> [DiffHunk] {
        guard let countStr = params["hunkCount"], let count = Int(countStr), count > 0 else { return [] }
        var hunks: [DiffHunk] = []
        for index in 0..<count {
            let oldText = params["hunk\(index).oldText"] ?? ""
            let newText = params["hunk\(index).newText"] ?? ""
            let summary = params["hunk\(index).summary"] ?? "Hunk \(index + 1)"
            hunks.append(DiffHunk(index: index, oldText: oldText, newText: newText, summary: summary))
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
                    let newContent = data["\(prefix).diffNew"]
                else { continue }

                var reviewParams = toolParams
                for (key, value) in data where key.hasPrefix(prefix + ".") {
                    reviewParams[String(key.dropFirst(prefix.count + 1))] = value
                }
                reviewParams["batchIndex"] = "\(batchIndex + 1)"
                reviewParams["batchCount"] = "\(batchCount)"

                steps.append(
                    fileChangeReviewStep(
                        FileChangeReviewStepRequest(
                            text: "待审查文件变更（\(batchIndex + 1)/\(batchCount)）：\(filePath)",
                            toolName: toolName,
                            toolParams: reviewParams,
                            callId: callId,
                            filePath: filePath,
                            oldContent: oldContent,
                            newContent: newContent
                        )
                    ))
            }
            return steps
        }

        guard let filePath = data["path"] ?? toolParams["path"],
            let oldContent = data["diffOld"],
            let newContent = data["diffNew"]
        else { return steps }

        var reviewParams = toolParams
        for (key, value) in data {
            reviewParams[key] = value
        }
        steps.append(
            fileChangeReviewStep(
                FileChangeReviewStepRequest(
                    text: "待审查文件变更：\(filePath)",
                    toolName: toolName,
                    toolParams: reviewParams,
                    callId: callId,
                    filePath: filePath,
                    oldContent: oldContent,
                    newContent: newContent
                )
            ))
        return steps
    }

    private static func fileChangeReviewStep(_ request: FileChangeReviewStepRequest) -> TaskStep {
        let hunks = extractHunks(from: request.toolParams)
        return TaskStep(
            kind: .reviewRequest,
            text: request.text,
            toolName: request.toolName,
            toolParams: request.toolParams,
            toolCallId: request.callId,
            isCollapsible: false,
            isCollapsed: false,
            diffFilePath: request.filePath,
            diffOldContent: request.oldContent,
            diffNewContent: request.newContent,
            approved: nil,
            diffHunks: hunks.isEmpty ? nil : hunks
        )
    }

    private static func resolvedFileChangePath(_ path: String, workspaceRoot: String) -> String {
        path.hasPrefix("/") ? path : (workspaceRoot as NSString).appendingPathComponent(path)
    }
}
