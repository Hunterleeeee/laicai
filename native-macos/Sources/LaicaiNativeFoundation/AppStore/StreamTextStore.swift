import Combine
import Foundation

/// High-frequency streaming text kept outside AppState.
///
/// During generation the model emits token deltas every few milliseconds.
/// Folding them into `AppState` invalidates the entire object graph on every
/// flush (sidebar, composer, workbench all re-render). This store keeps live
/// text in an independent publisher; only the card that renders a streaming
/// step subscribes to it, and `AppState` receives text only when a run ends.
@MainActor
public final class StreamTextStore: ObservableObject {
    /// Bumped whenever visible streaming content changes. Scroll-follow logic
    /// observes this counter instead of the whole object.
    @Published public private(set) var revision: UInt64 = 0

    private var texts: [UUID: String] = [:]
    private var reasonings: [UUID: String] = [:]

    public init() {}

    public func text(forThread id: UUID) -> String {
        texts[id] ?? ""
    }

    public func reasoning(forThread id: UUID) -> String {
        reasonings[id] ?? ""
    }

    public var isEmpty: Bool {
        texts.isEmpty && reasonings.isEmpty
    }

    func append(text delta: String, threadID: UUID) {
        guard !delta.isEmpty else { return }
        texts[threadID, default: ""] += delta
        revision &+= 1
    }

    func append(reasoning delta: String, threadID: UUID) {
        guard !delta.isEmpty else { return }
        reasonings[threadID, default: ""] += delta
        revision &+= 1
    }

    func clearText(threadID: UUID) {
        guard texts.removeValue(forKey: threadID) != nil else { return }
        revision &+= 1
    }

    func clearReasoning(threadID: UUID) {
        guard reasonings.removeValue(forKey: threadID) != nil else { return }
        revision &+= 1
    }

    func clearAll(threadID: UUID) {
        let removedText = texts.removeValue(forKey: threadID) != nil
        let removedReasoning = reasonings.removeValue(forKey: threadID) != nil
        if removedText || removedReasoning {
            revision &+= 1
        }
    }
}

/// Identifies which store + thread a streaming card should observe. Cards
/// receive this value only while rendering the live placeholder step.
public struct LiveStreamSource: Identifiable {
    public let store: StreamTextStore
    public let threadID: UUID

    public var id: UUID { threadID }

    public init(store: StreamTextStore, threadID: UUID) {
        self.store = store
        self.threadID = threadID
    }

    /// MainActor-isolated reads: SwiftUI card bodies run on the main actor.
    @MainActor public var currentText: String {
        store.text(forThread: threadID)
    }

    @MainActor public var currentReasoning: String {
        store.reasoning(forThread: threadID)
    }
}
