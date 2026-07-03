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

        prefetchSearchResults(recentSteps: recentSteps, taskContext: taskContext, result: &result)
        prefetchSiblingFiles(recentSteps: recentSteps, taskContext: taskContext, result: &result)
        prefetchFailedWriteTarget(recentSteps: recentSteps, taskContext: taskContext, result: &result)
        prefetchVerifyErrorFiles(recentSteps: recentSteps, taskContext: taskContext, result: &result)
        prefetchHeaderFiles(recentSteps: recentSteps, taskContext: taskContext, result: &result)

        return result
    }

    private static func prefetchSearchResults(
        recentSteps: ArraySlice<TaskStep>,
        taskContext: TaskContext,
        result: inout SpeculativeResult
    ) {
        guard let lastSearch = recentSteps.last(where: { $0.toolName == "code.search" && $0.kind == .toolResult }),
              !lastSearch.text.hasPrefix("未找到") else { return }
        let paths = extractReadablePaths(fromSearchOutput: lastSearch.text, workspaceRoot: taskContext.workspaceRoot, limit: 2)
        for path in paths where !taskContext.memory.readFiles.contains(path) {
            guard !Task.isCancelled else { return }
            guard let content = try? String(contentsOfFile: path, encoding: .utf8), content.count < 100_000 else { continue }
            result.cachedFiles[path] = content
            let signatures = signatureSummary(from: content)
            if !signatures.isEmpty { result.summaries[path] = String(signatures.prefix(300)) }
        }
    }

    private static func signatureSummary(from content: String) -> String {
        let sigPatterns = ["func ", "class ", "struct ", "enum ", "protocol ", "extension ", "def ", "interface ", "export "]
        return content.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in sigPatterns.contains(where: { line.hasPrefix($0) }) }
            .prefix(8)
            .joined(separator: "; ")
    }

    private static func prefetchSiblingFiles(
        recentSteps: ArraySlice<TaskStep>,
        taskContext: TaskContext,
        result: inout SpeculativeResult
    ) {
        guard let lastRead = recentSteps.last(where: { $0.toolName == "file.read" && $0.kind == .toolCall }),
              let path = lastRead.toolParams?["path"] else { return }
        let dir = (path as NSString).deletingLastPathComponent
        guard !dir.isEmpty, !Task.isCancelled else { return }
        let ext = (path as NSString).pathExtension.lowercased()
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let sameType = siblings.filter { (($0 as NSString).pathExtension.lowercased()) == ext }.prefix(3)
        for sibling in sameType {
            guard !Task.isCancelled else { return }
            let siblingPath = (dir as NSString).appendingPathComponent(sibling)
            cacheSmallFile(path: siblingPath, limit: 50_000, taskContext: taskContext, result: &result)
        }
    }

    private static func prefetchFailedWriteTarget(
        recentSteps: ArraySlice<TaskStep>,
        taskContext: TaskContext,
        result: inout SpeculativeResult
    ) {
        guard let lastFail = recentSteps.last(where: { $0.isFailure == true && isFileChangeTool($0.toolName ?? "") }) else {
            return
        }
        let path = pathForFileChange(callStep: lastFail)
        cacheSmallFile(path: path, limit: 100_000, taskContext: taskContext, result: &result)
    }

    private static func prefetchVerifyErrorFiles(
        recentSteps: ArraySlice<TaskStep>,
        taskContext: TaskContext,
        result: inout SpeculativeResult
    ) {
        guard let lastVerify = recentSteps.last(where: {
            $0.toolName == "verify.build" && $0.isFailure == true && $0.kind == .toolResult
        }) else { return }
        let errorPaths = lastVerify.text.components(separatedBy: .newlines)
            .compactMap { pathFromErrorLine($0, workspaceRoot: taskContext.workspaceRoot) }
        for path in Set(errorPaths).prefix(3) {
            guard !Task.isCancelled else { return }
            cacheSmallFile(path: path, limit: 100_000, taskContext: taskContext, result: &result)
        }
    }

    private static func pathFromErrorLine(_ line: String, workspaceRoot: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let colonIdx = trimmed.firstIndex(of: ":") else { return nil }
        let candidate = String(trimmed[..<colonIdx])
        if candidate.hasPrefix("/") && FileManager.default.fileExists(atPath: candidate) { return candidate }
        let absolute = (workspaceRoot as NSString).appendingPathComponent(candidate)
        return FileManager.default.fileExists(atPath: absolute) ? absolute : nil
    }

    private static func prefetchHeaderFiles(
        recentSteps: ArraySlice<TaskStep>,
        taskContext: TaskContext,
        result: inout SpeculativeResult
    ) {
        guard recentSteps.contains(where: { $0.toolName == "file.edit" && $0.kind == .toolResult && !$0.isFailure }),
              let path = recentSteps.last(where: { $0.toolName == "file.edit" && $0.kind == .toolCall })?.toolParams?["path"] else {
            return
        }
        let ext = (path as NSString).pathExtension.lowercased()
        let headerExts: [String: String] = ["swift": "swift", "c": "h", "cpp": "h", "m": "h", "mm": "h"]
        guard let headerExt = headerExts[ext], headerExt != ext else { return }
        let dir = (path as NSString).deletingLastPathComponent
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        for sibling in siblings.filter({ ($0 as NSString).pathExtension == headerExt }).prefix(2) {
            guard !Task.isCancelled else { return }
            let siblingPath = (dir as NSString).appendingPathComponent(sibling)
            cacheSmallFile(path: siblingPath, limit: 50_000, taskContext: taskContext, result: &result)
        }
    }

    private static func cacheSmallFile(
        path: String,
        limit: Int,
        taskContext: TaskContext,
        result: inout SpeculativeResult
    ) {
        guard !path.isEmpty,
              !taskContext.memory.readFiles.contains(path),
              result.cachedFiles[path] == nil,
              let content = try? String(contentsOfFile: path, encoding: .utf8),
              content.count < limit else { return }
        result.cachedFiles[path] = content
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
            if let candidatePath = candidate,
               FileManager.default.fileExists(atPath: candidatePath),
               !paths.contains(candidatePath) {
                paths.append(candidatePath)
            }
        }
        return paths
    }
}
