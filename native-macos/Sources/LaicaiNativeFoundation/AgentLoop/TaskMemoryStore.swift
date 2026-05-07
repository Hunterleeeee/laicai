import Foundation
import LaicaiNativeDomain

// MARK: - Cross-Session Task Memory Store

public enum TaskMemoryStore {
    private static let fileName = ".laicai-memory.json"
    private static let historyFileName = ".laicai-memory-history.json"
    private static let maxReadFiles = 50
    private static let maxSearchedQueries = 30
    private static let maxConclusions = 10
    private static let maxHistoryEntries = 20

    // MARK: - Keyword Index

    /// Build a keyword to file paths index from file summaries for fast retrieval.
    public static func buildKeywordIndex(from memory: TaskMemory) -> [String: [String]] {
        var index: [String: [String]] = [:]
        let stopWords: Set<String> = ["the", "a", "an", "is", "are", "was", "were", "be", "been",
            "being", "have", "has", "had", "do", "does", "did", "will", "would", "could",
            "should", "may", "might", "shall", "can", "need", "dare", "ought", "used",
            "to", "of", "in", "for", "on", "with", "at", "by", "from", "as", "into",
            "through", "during", "before", "after", "above", "below", "between", "out",
            "off", "over", "under", "again", "further", "then", "once", "and", "but",
            "or", "nor", "not", "so", "yet", "both", "either", "neither", "each",
            "every", "all", "any", "few", "more", "most", "other", "some", "such",
            "no", "only", "own", "same", "than", "too", "very", "just", "because",
            "if", "when", "where", "how", "what", "which", "who", "this", "that",
            "these", "those", "的", "了", "在", "是", "我", "有", "和", "就", "不",
            "人", "都", "一", "一个", "上", "也", "很", "到", "说", "要", "去", "你",
            "会", "着", "没有", "看", "好", "自己", "这"]

        for (filePath, summary) in memory.fileSummaries {
            let words = summary.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 2 && !stopWords.contains($0) }
            for word in words {
                index[word, default: []].append(filePath)
            }
        }

        for conclusion in memory.stageConclusions {
            let words = conclusion.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 2 && !stopWords.contains($0) }
            for word in words {
                index[word, default: []].append("conclusion:\(conclusion.prefix(50))")
            }
        }

        for key in index.keys {
            index[key] = Array(Set(index[key] ?? []))
        }
        return index
    }

    /// Search persisted memory by keyword, returning matching file summaries and conclusions.
    public static func search(workspaceRoot: String, query: String, limit: Int = 10) -> [String] {
        let memory = load(workspaceRoot: workspaceRoot)
        guard !memory.isEmpty else { return [] }
        let index = buildKeywordIndex(from: memory)
        let queryWords = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        var scored: [String: Int] = [:]
        for word in queryWords {
            if let paths = index[word] {
                for path in paths {
                    scored[path, default: 0] += 1
                }
            }
        }
        return scored.sorted { $0.value > $1.value }.prefix(limit).map { $0.key }
    }

    // MARK: - Session History

    private struct HistoryEntry: Codable, Sendable {
        let timestamp: Date
        let taskDescription: String
        let conclusions: [String]
        let filesModified: [String]
    }

    public static func appendHistory(memory: TaskMemory, workspaceRoot: String, taskDescription: String) {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return }
        let path = (root as NSString).appendingPathComponent(historyFileName)

        var history: [HistoryEntry] = []
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            history = decoded
        }

        let entry = HistoryEntry(
            timestamp: .now,
            taskDescription: String(taskDescription.prefix(200)),
            conclusions: Array(memory.stageConclusions.suffix(5)),
            filesModified: Array(Set(memory.pendingFiles).prefix(20))
        )
        history.append(entry)
        if history.count > maxHistoryEntries {
            history = Array(history.suffix(maxHistoryEntries))
        }

        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public static func loadHistory(workspaceRoot: String) -> [(timestamp: Date, description: String, conclusions: [String])] {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return [] }
        let path = (root as NSString).appendingPathComponent(historyFileName)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let history = try? JSONDecoder().decode([HistoryEntry].self, from: data) else {
            return []
        }
        return history.map { (timestamp: $0.timestamp, description: $0.taskDescription, conclusions: $0.conclusions) }
    }

    // MARK: - Save / Load / Merge

    public static func save(_ memory: TaskMemory, workspaceRoot: String) {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty, !memory.isEmpty else { return }

        var trimmed = memory
        trimmed.readFiles = Array(Set(trimmed.readFiles).prefix(maxReadFiles))
        trimmed.searchedQueries = Array(Set(trimmed.searchedQueries).prefix(maxSearchedQueries))
        trimmed.stageConclusions = Array(trimmed.stageConclusions.suffix(maxConclusions))
        trimmed.checkpoints = Array(trimmed.checkpoints.suffix(5))
        trimmed.failedTools = Array(Set(trimmed.failedTools).prefix(20))
        trimmed.userDecisions = Array(trimmed.userDecisions.suffix(15))
        trimmed.fileContentCache = [:]
        if trimmed.fileSummaries.count > maxReadFiles {
            let sorted = trimmed.fileSummaries.sorted { $0.key < $1.key }
            trimmed.fileSummaries = Dictionary(uniqueKeysWithValues: Array(sorted.suffix(maxReadFiles)))
        }
        trimmed.updatedAt = .now

        let path = (root as NSString).appendingPathComponent(fileName)
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public static func load(workspaceRoot: String) -> TaskMemory {
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return TaskMemory() }
        let path = (root as NSString).appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let memory = try? JSONDecoder().decode(TaskMemory.self, from: data) else {
            return TaskMemory()
        }
        if let updated = memory.updatedAt, Date().timeIntervalSince(updated) > 7 * 86400 {
            return TaskMemory()
        }
        return memory
    }

    public static func merge(_ persisted: TaskMemory, into current: TaskMemory) -> TaskMemory {
        var result = current
        let allRead = Set(persisted.readFiles).union(current.readFiles)
        result.readFiles = Array(allRead.prefix(maxReadFiles))
        let allSearched = Set(persisted.searchedQueries).union(current.searchedQueries)
        result.searchedQueries = Array(allSearched.prefix(maxSearchedQueries))
        var summaries = persisted.fileSummaries
        for (key, value) in current.fileSummaries {
            summaries[key] = value
        }
        result.fileSummaries = summaries
        if result.stageConclusions.isEmpty {
            result.stageConclusions = Array(persisted.stageConclusions.suffix(maxConclusions))
        }
        if result.checkpoints.isEmpty {
            result.checkpoints = persisted.checkpoints
        }
        if result.verificationStatus == nil {
            result.verificationStatus = persisted.verificationStatus
        }
        let allPending = Set(persisted.pendingFiles).union(current.pendingFiles)
        result.pendingFiles = Array(allPending.prefix(30))
        if result.userDecisions.isEmpty {
            result.userDecisions = Array(persisted.userDecisions.suffix(15))
        }
        result.updatedAt = .now
        return result
    }
}
