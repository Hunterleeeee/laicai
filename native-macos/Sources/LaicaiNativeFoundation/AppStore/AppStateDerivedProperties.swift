import Foundation
import LaicaiNativeDomain

extension AppState {
    private static let summarySearchRecentStepLimit = 1

    private var visibleThreads: [Thread] {
        threads.filter { thread in
            !thread.isEmptyPlaceholder || thread.id == selectedThreadID
        }
    }

    private static func lightweightSearchIndex(for thread: Thread) -> String {
        var parts = [
            thread.title,
            thread.preview,
            thread.goal ?? "",
            thread.modelName,
            thread.status.title,
            thread.executionState.title,
            thread.context.workspaceRoot,
        ]
        let recentStepParts = thread.steps.suffix(summarySearchRecentStepLimit).flatMap { step in
            [step.text, step.toolName ?? ""]
        }
        parts.append(contentsOf: recentStepParts)
        return parts.joined(separator: " ").lowercased()
    }

    public var agents: [AgentRecord] {
        visibleThreads
            .map { AgentRecord(thread: $0, includeEvents: true) }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    public var agentSummaries: [AgentRecord] {
        visibleThreads
            .map { AgentRecord(thread: $0, includeEvents: false) }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    public var selectedAgentID: UUID? { selectedThreadID }

    public var selectedAgent: AgentRecord? {
        guard let id = selectedThreadID,
            let thread = threads.first(where: { $0.id == id })
        else { return nil }
        return AgentRecord(thread: thread, includeEvents: true)
    }

    public var activeAgents: [AgentRecord] {
        agents.filter { [.planning, .running, .waitingForApproval, .blocked, .paused].contains($0.state) }
    }

    public var continuableAgents: [AgentRecord] {
        visibleThreads.filter { !$0.isEmptyPlaceholder && $0.canContinue }
            .map { AgentRecord(thread: $0, includeEvents: false) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public var completedAgents: [AgentRecord] {
        agents.filter { $0.state == .completed }
    }

    public var archivedAgents: [AgentRecord] {
        agents.filter(\.isArchived)
    }

    public var activeConnector: ConnectorProfile? {
        connectors.first(where: { $0.id == activeConnectorID })
    }

    public var pendingReviewCount: Int {
        threads.reduce(0) { count, thread in
            count + thread.steps.filter { $0.kind == .reviewRequest && $0.approved == nil }.count
        }
    }

    /// Estimated progress (0.0-1.0) for the currently running task based on tool call iterations.
    public var estimatedProgress: Double? {
        guard isGenerating, let id = selectedThreadID,
            let thread = threads.first(where: { $0.id == id })
        else { return nil }
        let toolCalls = thread.steps.filter { $0.kind == .toolCall }.count
        guard toolCalls > 0 else { return nil }
        let expectedIterations = max(3.0, Double(thread.context.metadata["expectedIterations"] ?? "8") ?? 8.0)
        return min(0.95, Double(toolCalls) / expectedIterations)
    }

    public var selectedThread: Thread? {
        guard let id = selectedThreadID else { return nil }
        return threads.first(where: { $0.id == id })
    }

    public var threadRecords: [ThreadRecord] {
        visibleThreads.map { ThreadRecord(thread: $0, includeEvents: true) }.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    public var threadRecordSummaries: [ThreadRecord] {
        visibleThreads.map { ThreadRecord(thread: $0, includeEvents: false) }.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    public var filteredThreadRecords: [ThreadRecord] {
        let query = (debouncedSearchText.isEmpty ? searchText : debouncedSearchText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return threadRecords }
        let lower = query.lowercased()
        return visibleThreads.compactMap { thread in
            let metadata = [
                thread.title,
                thread.preview,
                thread.goal ?? "",
                thread.steps.last?.text ?? "",
                thread.modelName,
                thread.status.title,
                thread.executionState.title,
                thread.context.workspaceRoot,
            ].joined(separator: " ").lowercased()
            guard
                metadata.contains(lower)
                    || thread.steps.suffix(12).contains(where: { step in
                        step.text.lowercased().contains(lower)
                            || step.toolName?.lowercased().contains(lower) == true
                    })
            else {
                return nil
            }
            return ThreadRecord(thread: thread, includeEvents: true)
        }.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    public var filteredThreadRecordSummaries: [ThreadRecord] {
        let query = (debouncedSearchText.isEmpty ? searchText : debouncedSearchText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return threadRecordSummaries }
        let lower = query.lowercased()
        let visible = visibleThreads.filter { thread in
            Self.lightweightSearchIndex(for: thread).contains(lower)
        }
        return visible.map { ThreadRecord(thread: $0, includeEvents: false) }.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    public var threadSummaries: [ThreadRecord] { threadRecordSummaries }
    public var filteredThreads: [ThreadRecord] { filteredThreadRecords }
    public var filteredThreadSummaries: [ThreadRecord] { filteredThreadRecordSummaries }

    public mutating func invalidateThreadSummaryCache() {
        threadSummaryGeneration &+= 1
    }

    public mutating func selectThread(id: UUID?) {
        selectedThreadID = id
    }
}
