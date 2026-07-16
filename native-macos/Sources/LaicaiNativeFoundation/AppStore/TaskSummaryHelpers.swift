import Foundation
import LaicaiNativeDomain

extension AppStore {
    nonisolated static func generateSummaryCache(for thread: Thread) -> String {
        let recentStepCount = min(14, thread.steps.count)
        let earlySteps = thread.steps.dropLast(recentStepCount)
        guard !earlySteps.isEmpty else { return "" }

        var lines = ["\(earlySteps.count) 条早期步骤摘要"]
        let readFiles = uniqueValues(
            earlySteps.filter { $0.kind == .toolResult && $0.toolName == "file.read" && !$0.isFailure }
                .compactMap { $0.toolParams?["path"] }
        )
        let searchedQueries = uniqueValues(
            earlySteps.filter { $0.kind == .toolCall && $0.toolName == "code.search" }
                .compactMap { $0.toolParams?["query"] }
        )
        let failedTools = earlySteps.filter { $0.kind == .toolResult && $0.isFailure }
            .map { "\($0.toolName ?? "工具") 失败" }
        let conclusions = earlySteps.filter { $0.kind == .textOutput }
            .suffix(3)
            .map { compactSummaryText($0.text, limit: 260) }

        if !readFiles.isEmpty {
            lines.append("- 已读文件：\(readFiles.prefix(12).joined(separator: "、"))")
        }
        if !searchedQueries.isEmpty {
            lines.append("- 已搜索：\(searchedQueries.prefix(8).joined(separator: "、"))")
        }
        if !failedTools.isEmpty {
            lines.append("- 失败工具：\(uniqueValues(failedTools).prefix(6).joined(separator: "、"))")
        }
        if !conclusions.isEmpty {
            lines.append("- 早期结论：\(conclusions.joined(separator: " / "))")
        }
        return lines.joined(separator: "\n")
    }

    nonisolated static func uniqueValues(_ values: [String]) -> [String] {
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

    nonisolated static func compactSummaryText(_ text: String, limit: Int = 260) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(max(0, limit - 1))) + "…"
    }

    nonisolated static func errorProgressSummary(steps: [TaskStep]) -> String {
        let filesRead = Set(
            steps
                .filter { $0.kind == .toolResult && $0.toolName == "file.read" && !$0.isFailure }
                .compactMap { $0.toolParams?["path"] })
        let filesWritten = Set(
            steps
                .filter { $0.kind == .reviewRequest && $0.approved == true }
                .compactMap(\.diffFilePath))
        let toolCalls = steps.filter { $0.kind == .toolCall }.count
        let searches = steps.filter { $0.kind == .toolCall && ($0.toolName == "code.search" || $0.toolName == "web.search") }.count

        var parts: [String] = []
        if !filesRead.isEmpty { parts.append("读 \(filesRead.count) 文件") }
        if !filesWritten.isEmpty { parts.append("写 \(filesWritten.count) 文件") }
        if searches > 0 { parts.append("搜索 \(searches) 次") }
        if toolCalls > 0 && parts.isEmpty { parts.append("工具调用 \(toolCalls) 次") }
        return parts.joined(separator: "、")
    }
}
