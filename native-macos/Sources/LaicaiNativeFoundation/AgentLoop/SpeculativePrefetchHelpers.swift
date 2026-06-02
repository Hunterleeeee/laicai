import Foundation
import LaicaiNativeDomain

@MainActor
extension AgentLoop {
    // MARK: - G2: Speculative Pre-Fetch

    struct SpeculativeResult {
        var cachedFiles: [String: String] = [:]   // path → content
        var summaries: [String: String] = [:]      // path → summary
    }

    /// While LLM is thinking, predict what it'll need next and pre-read files.
    /// Returns data to merge into taskContext after the LLM call completes.
    @MainActor
    static func speculativePreFetch(
        iteration: Int,
        taskContext: TaskContext,
        task: AgentTask,
        toolRegistry: ToolRegistry
    ) async -> SpeculativeResult {
        var result = SpeculativeResult()
        let recentSteps = task.steps.suffix(10)

        // After code.search → pre-read top 2 result files
        if let lastSearch = recentSteps.last(where: { $0.toolName == "code.search" && $0.kind == .toolResult }),
           !lastSearch.text.hasPrefix("未找到") {
            let paths = Self.extractReadablePaths(fromSearchOutput: lastSearch.text, workspaceRoot: taskContext.workspaceRoot, limit: 2)
            for path in paths where !taskContext.memory.readFiles.contains(path) {
                guard !Task.isCancelled else { return result }
                if let content = try? String(contentsOfFile: path, encoding: .utf8), content.count < 100_000 {
                    result.cachedFiles[path] = content
                    let sigPatterns = ["func ", "class ", "struct ", "enum ", "protocol ", "extension ", "def ", "interface ", "export "]
                    let sigs = content.components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { line in sigPatterns.contains(where: { line.hasPrefix($0) }) }
                        .prefix(8).joined(separator: "; ")
                    if !sigs.isEmpty { result.summaries[path] = String(sigs.prefix(300)) }
                }
            }
        }

        // After file.read → pre-read sibling files in same directory
        if let lastRead = recentSteps.last(where: { $0.toolName == "file.read" && $0.kind == .toolCall }),
           let path = lastRead.toolParams?["path"] {
            let dir = (path as NSString).deletingLastPathComponent
            guard !dir.isEmpty, !Task.isCancelled else { return result }
            let ext = (path as NSString).pathExtension.lowercased()
            if let siblings = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                let sameType = siblings.filter { (($0 as NSString).pathExtension.lowercased()) == ext }.prefix(3)
                for sibling in sameType {
                    guard !Task.isCancelled else { return result }
                    let sibPath = (dir as NSString).appendingPathComponent(sibling)
                    if !taskContext.memory.readFiles.contains(sibPath),
                       taskContext.memory.fileContentCache[sibPath] == nil,
                       let content = try? String(contentsOfFile: sibPath, encoding: .utf8),
                       content.count < 50_000 {
                        result.cachedFiles[sibPath] = content
                    }
                }
            }
        }

        // After file.write/edit failure → pre-read the target file
        if let lastFail = recentSteps.last(where: { $0.isFailure == true && isFileChangeTool($0.toolName ?? "") }) {
            let path = pathForFileChange(callStep: lastFail)
            if !path.isEmpty,
               !taskContext.memory.readFiles.contains(path),
               !Task.isCancelled,
               let content = try? String(contentsOfFile: path, encoding: .utf8),
               content.count < 100_000 {
                result.cachedFiles[path] = content
            }
        }

        // After verify.build failure → pre-read files mentioned in error output
        if let lastVerify = recentSteps.last(where: { $0.toolName == "verify.build" && $0.isFailure == true && $0.kind == .toolResult }) {
            let errorPaths = lastVerify.text.components(separatedBy: .newlines)
                .compactMap { line -> String? in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    // Match "file.swift:123: error:" pattern
                    guard let colonIdx = trimmed.firstIndex(of: ":") else { return nil }
                    let candidate = String(trimmed[..<colonIdx])
                    if candidate.hasPrefix("/") && FileManager.default.fileExists(atPath: candidate) { return candidate }
                    let absolute = (taskContext.workspaceRoot as NSString).appendingPathComponent(candidate)
                    if FileManager.default.fileExists(atPath: absolute) { return absolute }
                    return nil
                }
            for path in Set(errorPaths).prefix(3) {
                guard !Task.isCancelled else { return result }
                if !taskContext.memory.readFiles.contains(path) && result.cachedFiles[path] == nil {
                    if let content = try? String(contentsOfFile: path, encoding: .utf8), content.count < 100_000 {
                        result.cachedFiles[path] = content
                    }
                }
            }
        }

        // After file.edit success → pre-read nearby import/header files for verify context
        if recentSteps.contains(where: { $0.toolName == "file.edit" && $0.kind == .toolResult && !$0.isFailure }),
           let path = recentSteps.last(where: { $0.toolName == "file.edit" && $0.kind == .toolCall })?.toolParams?["path"] {
            let ext = (path as NSString).pathExtension.lowercased()
            let headerExts: [String: String] = ["swift": "swift", "c": "h", "cpp": "h", "m": "h", "mm": "h"]
            if let headerExt = headerExts[ext], headerExt != ext {
                let dir = (path as NSString).deletingLastPathComponent
                if let siblings = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                    for sibling in siblings.filter({ ($0 as NSString).pathExtension == headerExt }).prefix(2) {
                        guard !Task.isCancelled else { return result }
                        let sibPath = (dir as NSString).appendingPathComponent(sibling)
                        if !taskContext.memory.readFiles.contains(sibPath) && result.cachedFiles[sibPath] == nil {
                            if let content = try? String(contentsOfFile: sibPath, encoding: .utf8), content.count < 50_000 {
                                result.cachedFiles[sibPath] = content
                            }
                        }
                    }
                }
            }
        }

        return result
    }

    /// Extract multiple readable paths from search output
    static func extractReadablePaths(fromSearchOutput output: String, workspaceRoot: String, limit: Int) -> [String] {
        var paths: [String] = []
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            guard paths.count < limit else { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            var candidate: String?
            if trimmed.hasPrefix("/") {
                candidate = trimmed.components(separatedBy: ":").first
            } else if trimmed.contains(".") && !trimmed.hasPrefix("http") {
                let parts = trimmed.components(separatedBy: .whitespaces)
                if let first = parts.first, first.contains("/") {
                    candidate = (workspaceRoot as NSString).appendingPathComponent(first.components(separatedBy: ":").first ?? first)
                }
            }
            if let c = candidate, FileManager.default.fileExists(atPath: c), !paths.contains(c) {
                paths.append(c)
            }
        }
        return paths
    }
}
