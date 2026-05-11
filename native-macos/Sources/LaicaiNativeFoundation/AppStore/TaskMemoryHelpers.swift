import Foundation
import LaicaiNativeDomain

extension AppStore {
    static func taskMemory(from thread: Thread) -> TaskMemory {
        let readFiles = uniqueMemoryValues(thread.steps
            .filter { $0.kind == .toolResult && $0.toolName == "file.read" && !$0.isFailure }
            .compactMap { $0.toolParams?["path"] })
        let searchedQueries = uniqueMemoryValues(thread.steps
            .filter { $0.kind == .toolCall && $0.toolName == "code.search" }
            .compactMap { $0.toolParams?["query"] })
        let failedTools = uniqueMemoryValues(Dictionary(grouping: thread.steps.filter { $0.kind == .toolResult && $0.isFailure }, by: { $0.toolName ?? "tool" })
            .map { "\($0.key) ×\($0.value.count)" }
            .sorted())
        let conclusions = thread.steps
            .filter { $0.kind == .textOutput && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(3)
            .map { compactMemoryText($0.text, limit: 240) }
        let checkpoints = thread.steps
            .filter { $0.kind == .aiThinking && ($0.text.hasPrefix("任务检查点") || $0.text.hasPrefix("阶段总结")) }
            .suffix(2)
            .map { compactMemoryText($0.text, limit: 360) }
        let verification: String?
        if thread.status == .completed {
            verification = "已形成最终回复，需以后续验证命令为准。"
        } else if thread.status == .failed {
            verification = "任务失败或未完成，继续时优先恢复失败工具或补齐证据。"
        } else if thread.status == .cancelled {
            verification = "任务被取消，继续时沿用已读上下文并从未完成处推进。"
        } else {
            verification = nil
        }

        return TaskMemory(
            readFiles: readFiles,
            searchedQueries: searchedQueries,
            failedTools: failedTools,
            stageConclusions: uniqueMemoryValues(conclusions),
            checkpoints: uniqueMemoryValues(checkpoints),
            verificationStatus: verification,
            pendingFiles: pendingFileCandidates(from: thread.steps, alreadyRead: Set(readFiles)),
            userDecisions: thread.steps
                .filter { $0.kind == .reviewResult }
                .suffix(5)
                .map { compactMemoryText($0.text, limit: 160) },
            updatedAt: .now
        )
    }

    static func pendingFileCandidates(from steps: [TaskStep], alreadyRead: Set<String>) -> [String] {
        var candidates: [String] = []
        for step in steps where step.kind == .toolResult && step.toolName == "code.search" && !step.isFailure {
            let lines = step.text.components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("/") || trimmed.hasPrefix("./") || trimmed.hasPrefix("src/") || trimmed.hasPrefix("Sources/") {
                    let path = trimmed.components(separatedBy: ":").first ?? trimmed
                    let cleanPath = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
                    if !alreadyRead.contains(cleanPath) && !cleanPath.isEmpty {
                        candidates.append(cleanPath)
                    }
                }
            }
        }
        for step in steps where step.kind == .toolResult && step.toolName == "workspace.index" && !step.isFailure {
            let lines = step.text.components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("入口") || trimmed.hasPrefix("测试") || trimmed.hasPrefix("配置") {
                    if let colonRange = trimmed.range(of: "：") ?? trimmed.range(of: ":") {
                        let afterColon = trimmed[colonRange.upperBound...].trimmingCharacters(in: .whitespaces)
                        if !afterColon.isEmpty && !alreadyRead.contains(afterColon) {
                            candidates.append(afterColon)
                        }
                    }
                }
            }
        }
        return Array(uniqueMemoryValues(candidates).prefix(12))
    }

    static func uniqueMemoryValues(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    static func compactMemoryText(_ text: String, limit: Int) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        return "\(cleaned.prefix(limit))…"
    }
}
