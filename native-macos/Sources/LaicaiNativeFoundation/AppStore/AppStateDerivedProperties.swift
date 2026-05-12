import Foundation
import LaicaiNativeDomain

extension AppState {
    public var selectedThreadSource: ThreadSource? {
        threads.first(where: { $0.id == selectedThreadID })?.source
    }

    public var sessions: [ChatSession] {
        threads.filter { $0.source == .session }.map { ChatSession(thread: $0) }
    }

    public var selectedSessionID: UUID? {
        threads.first(where: { $0.id == selectedThreadID })?.source == .session ? selectedThreadID : nil
    }

    public var tasks: [AgentTask] {
        threads.filter { $0.source == .task }.map { AgentTask(thread: $0) }
    }

    public var selectedTaskID: UUID? {
        threads.first(where: { $0.id == selectedThreadID })?.source == .task ? selectedThreadID : nil
    }

    public var selectedSession: ChatSession? {
        guard let id = selectedThreadID, let thread = threads.first(where: { $0.id == id }), thread.source == .session else { return nil }
        return ChatSession(thread: thread)
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
              let thread = threads.first(where: { $0.id == id }),
              thread.source == .task else { return nil }
        let toolCalls = thread.steps.filter { $0.kind == .toolCall }.count
        guard toolCalls > 0 else { return nil }
        let expectedIterations = max(3.0, Double(thread.context.metadata["expectedIterations"] ?? "8") ?? 8.0)
        return min(0.95, Double(toolCalls) / expectedIterations)
    }

    public var selectedTask: AgentTask? {
        guard let id = selectedThreadID, let thread = threads.first(where: { $0.id == id }), thread.source == .task else { return nil }
        return AgentTask(thread: thread)
    }

    public var selectedThread: Thread? {
        guard let id = selectedThreadID else { return nil }
        return threads.first(where: { $0.id == id })
    }

    public var threadRecords: [ThreadRecord] {
        threads.filter { !$0.isEmptyPlaceholder }.map { ThreadRecord(thread: $0, includeEvents: true) }.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    public var threadRecordSummaries: [ThreadRecord] {
        threads.filter { !$0.isEmptyPlaceholder }.map { ThreadRecord(thread: $0, includeEvents: false) }.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    public var filteredThreadRecords: [ThreadRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return threadRecords }
        return threadRecords.filter { record in
            record.title.localizedCaseInsensitiveContains(query)
                || record.preview.localizedCaseInsensitiveContains(query)
                || record.events.contains { event in
                    event.text.localizedCaseInsensitiveContains(query)
                }
        }
    }

    public var filteredThreadRecordSummaries: [ThreadRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return threadRecordSummaries }
        return filteredThreadRecords
    }

    public var threads_legacy: [ThreadRecord] { threadRecords }
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
