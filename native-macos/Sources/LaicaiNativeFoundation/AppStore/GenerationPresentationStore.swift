import Combine
import Foundation

/// High-frequency, UI-only generation state kept outside AppState.
/// Keeping this publisher independent prevents generation ticks from being
/// coupled to the settings/sidebar/workbench state graph.
@MainActor
public final class GenerationPresentationStore: ObservableObject {
    public struct Snapshot: Equatable, Sendable {
        public let isGenerating: Bool
        public let activity: String
        public let startedAt: Date?

        public init(isGenerating: Bool = false, activity: String = "", startedAt: Date? = nil) {
            self.isGenerating = isGenerating
            self.activity = activity
            self.startedAt = startedAt
        }
    }

    @Published public private(set) var revision: UInt64 = 0
    private var snapshots: [UUID: Snapshot] = [:]

    public init() {}

    public func snapshot(for threadID: UUID) -> Snapshot {
        snapshots[threadID] ?? Snapshot()
    }

    public func markStarted(threadID: UUID, activity: String, startedAt: Date) {
        set(threadID: threadID, snapshot: Snapshot(isGenerating: true, activity: activity, startedAt: startedAt))
    }

    public func updateActivity(threadID: UUID, activity: String) {
        let old = snapshot(for: threadID)
        set(threadID: threadID, snapshot: Snapshot(isGenerating: old.isGenerating, activity: activity, startedAt: old.startedAt))
    }

    public func finish(threadID: UUID) {
        guard snapshots.removeValue(forKey: threadID) != nil else { return }
        revision &+= 1
    }

    public func reset() {
        guard !snapshots.isEmpty else { return }
        snapshots.removeAll()
        revision &+= 1
    }

    private func set(threadID: UUID, snapshot: Snapshot) {
        guard snapshots[threadID] != snapshot else { return }
        snapshots[threadID] = snapshot
        revision &+= 1
    }
}
