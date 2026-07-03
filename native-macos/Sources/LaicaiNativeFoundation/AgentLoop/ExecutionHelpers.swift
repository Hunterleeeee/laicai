import Foundation
import LaicaiNativeDomain

@MainActor
extension AgentLoop {
    /// Parse JSON arguments into [String: String] for display
    func parseParamsFromJSON(_ json: String) -> [String: String] {
        Self.displayParamsFromJSON(json)
    }

    static func displayParamsFromJSON(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict.mapValues { value in
            if let bool = value as? Bool {
                return bool ? "true" : "false"
            }
            if let str = value as? String {
                return String(str.prefix(100))
            }
            return "\(value)"
        }
    }

    static func circuitBreakerTarget(for step: TaskStep) -> String {
        guard let params = step.toolParams else { return "unknown" }
        let candidates = [
            params["path"],
            params["sourcePath"],
            params["outputPath"],
            params["pdfPath"],
            params["query"],
            params["command"]
        ]
        return candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "unknown"
    }

    nonisolated static var fileChangeTools: Set<String> {
        ["file.write", "file.edit", "diff.apply"]
    }

    nonisolated static var explicitApprovalSideEffectTools: Set<String> { [] }

    nonisolated static func isFileChangeTool(_ toolName: String) -> Bool {
        fileChangeTools.contains(ToolNameCodec.canonicalName(toolName))
    }

    nonisolated static func isExplicitApprovalSideEffectTool(_ toolName: String) -> Bool {
        explicitApprovalSideEffectTools.contains(ToolNameCodec.canonicalName(toolName))
    }

    nonisolated static func isFileChangeTool(toolName: String, tool: (any LaicaiTool)?) -> Bool {
        if tool?.executionPolicy == .fileChangeReview { return true }
        return isFileChangeTool(toolName)
    }

    nonisolated static func requiresExplicitUserApprovalBeforeExecution(toolName: String, tool: any LaicaiTool) -> Bool {
        switch tool.executionPolicy {
        case .explicitUserApproval:
            return true
        case .fileChangeReview, .immediate:
            return false
        }
    }

    nonisolated static func canonicalToolSet(_ names: Set<String>?) -> Set<String>? {
        names.map { Set($0.map(ToolNameCodec.canonicalName)) }
    }

    nonisolated static func allowsTool(_ toolName: String, allowedTools: Set<String>?) -> Bool {
        guard let allowedTools, !allowedTools.isEmpty else { return true }
        return canonicalToolSet(allowedTools)?.contains(ToolNameCodec.canonicalName(toolName)) ?? false
    }

    func hydrateRuntimeContract(from context: TaskContext, into task: inout AgentTask) {
        if let protocolJSON = context.metadata["taskProtocolJSON"],
           let data = protocolJSON.data(using: .utf8),
           let taskProtocol = try? JSONDecoder().decode(AgentTaskProtocol.self, from: data) {
            task.taskProtocol = taskProtocol
        }
        if let ledgerJSON = context.metadata["executionLedgerJSON"],
           let data = ledgerJSON.data(using: .utf8),
           var ledger = try? JSONDecoder().decode(AgentExecutionLedger.self, from: data) {
            ledger.transition(to: .gatheringEvidence, reason: "AgentLoop 开始运行")
            task.executionLedger = ledger
        }
    }

    nonisolated static func approvalRequiredToolResult(toolName: String) -> ToolResult {
        ToolResult(
            output: "已阻止工具调用：\(toolName)。该工具会影响真实系统或外部应用，必须由用户显式确认后才能执行。",
            data: ["approvalRequired": "true"],
            success: false,
            error: "approval_required"
        )
    }

    nonisolated static func pathForFileChange(callStep: TaskStep, toolResult: ToolResult? = nil) -> String {
        toolResult?.data?["path"]
            ?? toolResult?.data?["outputPath"]
            ?? callStep.toolParams?["outputPath"]
            ?? callStep.toolParams?["path"]
            ?? callStep.toolParams?["sourcePath"]
            ?? ""
    }

    // G9: Allow file edits on DIFFERENT files to run in parallel
    static func scheduledToolCallBatches(
        _ calls: [ToolCallEntry]
    ) -> [[ToolCallEntry]] {
        var batches: [[ToolCallEntry]] = []
        var currentBatch: [ToolCallEntry] = []
        var currentBatchPaths: Set<String> = []
        var currentBatchIsReadOnly = true

        for call in calls {
            let toolName = call.callStep.toolName ?? call.apiToolName
            let params = call.toolParams
            let exclusivity = toolExclusivity(toolName: toolName, params: params)

            switch exclusivity {
            case .fullyExclusive:
                // shell.exec, git write — must run alone
                if !currentBatch.isEmpty {
                    batches.append(currentBatch)
                    currentBatch.removeAll()
                    currentBatchPaths.removeAll()
                    currentBatchIsReadOnly = true
                }
                batches.append([call])
            case .fileExclusive(let path):
                // File change tools can parallel if they target different files.
                if currentBatchPaths.contains(path) || (!currentBatchIsReadOnly && !currentBatchPaths.isEmpty) {
                    batches.append(currentBatch)
                    currentBatch.removeAll()
                    currentBatchPaths.removeAll()
                    currentBatchIsReadOnly = true
                }
                currentBatch.append(call)
                currentBatchPaths.insert(path)
                currentBatchIsReadOnly = false
            case .notExclusive:
                // read-only tools — always batch together
                if !currentBatchIsReadOnly {
                    batches.append(currentBatch)
                    currentBatch.removeAll()
                    currentBatchPaths.removeAll()
                    currentBatchIsReadOnly = true
                }
                currentBatch.append(call)
            }
        }

        if !currentBatch.isEmpty {
            batches.append(currentBatch)
        }
        return batches
    }

    private enum ToolExclusivity {
        case notExclusive
        case fileExclusive(String)  // exclusive per-file path
        case fullyExclusive         // must run alone
    }

    private static func toolExclusivity(toolName: String, params: [String: String]) -> ToolExclusivity {
        if toolName == "shell.exec" { return .fullyExclusive }
        if isFileChangeTool(toolName) {
            let path = params["path"] ?? "unknown"
            return .fileExclusive(path)
        }
        if toolName == "git" {
            let subcommand = params["subcommand"] ?? ""
            let isWrite = ["add", "commit", "commit-auto", "checkout", "switch", "branch-create"].contains {
                subcommand.hasPrefix($0)
            }
            return isWrite ? .fullyExclusive : .notExclusive
        }
        return .notExclusive
    }

    static func usesOllamaChat(_ connector: ConnectorProfile) -> Bool {
        LiveChatRuntime.usesOllamaNativeProtocol(endpoint: connector.endpoint, kind: connector.kind)
    }

}
