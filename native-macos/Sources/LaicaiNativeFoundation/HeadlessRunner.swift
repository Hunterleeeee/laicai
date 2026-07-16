import Foundation
import LaicaiNativeDomain

// G17: CI/Headless mode — run agent tasks without GUI
// Usage: LAICAI_HEADLESS=1 LAICAI_TASK="your task" LAICAI_WORKSPACE="/path" ./Laicai
// Or via AppStore: HeadlessRunner.runIfNeeded(store:)

public final class HeadlessRunner {
    public static let shared = HeadlessRunner()
    private init() {}

    /// Check if headless mode is requested via environment or launch arguments
    public var isHeadless: Bool {
        ProcessInfo.processInfo.environment["LAICAI_HEADLESS"] == "1"
            || CommandLine.arguments.contains("--headless")
    }

    /// The task prompt from environment
    public var taskPrompt: String? {
        ProcessInfo.processInfo.environment["LAICAI_TASK"]
            ?? extractArgValue("--task")
    }

    /// Workspace override
    public var workspace: String? {
        ProcessInfo.processInfo.environment["LAICAI_WORKSPACE"]
            ?? extractArgValue("--workspace")
    }

    /// Connector name override
    public var connectorName: String? {
        ProcessInfo.processInfo.environment["LAICAI_CONNECTOR"]
            ?? extractArgValue("--connector")
    }

    /// Auto-approve all reviews (dangerous, for CI only)
    public var autoApprove: Bool {
        ProcessInfo.processInfo.environment["LAICAI_AUTO_APPROVE"] == "1"
            || CommandLine.arguments.contains("--auto-approve")
    }

    /// Output format: text (default) or json
    public var outputFormat: String {
        ProcessInfo.processInfo.environment["LAICAI_OUTPUT_FORMAT"]
            ?? extractArgValue("--output-format")
            ?? "text"
    }

    /// Run the headless task using the provided store
    @MainActor
    public func runIfNeeded(store: AppStore) -> Bool {
        guard isHeadless,
            let rawPrompt = taskPrompt,
            !rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        if let workspacePath = workspace, !workspacePath.isEmpty {
            store.updateWorkspacePath(workspacePath)
        }
        if let connectorName, !connectorName.isEmpty {
            if let connector = store.state.connectors.first(where: { $0.name == connectorName }) {
                store.selectConnector(id: connector.id)
            }
        }

        fputs("🤖 Laicai Headless Mode\n", stderr)
        fputs("  Task: \(prompt)\n", stderr)
        fputs("  Workspace: \(store.state.settings.workspacePath)\n", stderr)
        fputs("  Connector: \(store.state.activeConnector?.name ?? "none")\n", stderr)
        fputs("  Auto-approve: \(autoApprove)\n\n", stderr)

        store.updateDraft(prompt)
        store.sendDraft()
        let launchedThreadID = store.state.selectedThreadID

        Task { @MainActor in
            await monitor(store: store, launchedThreadID: launchedThreadID)
        }

        return true
    }

    @MainActor
    private func monitor(store: AppStore, launchedThreadID: UUID?) async {
        while store.state.isGenerating {
            try? await Task.sleep(for: .seconds(1))
            if autoApprove {
                approvePendingReviews(in: store)
            }
        }

        let launchedThread = launchedThreadID.flatMap { id in
            store.state.threads.first(where: { $0.id == id })
        }
        let result = Self.result(for: launchedThread)
        printResult(result)
        exit(Self.exitCode(for: result))
    }

    @MainActor
    private func approvePendingReviews(in store: AppStore) {
        for thread in store.state.threads {
            for step in thread.steps where step.kind == .reviewRequest && step.approved == nil {
                store.approveReview(taskID: thread.id, stepID: step.id)
                fputs("  ✅ Auto-approved review: \(step.diffFilePath ?? "unknown")\n", stderr)
            }
        }
    }

    private func printResult(_ result: HeadlessResult) {
        if outputFormat == "json" {
            if let data = try? JSONEncoder().encode(result),
                let json = String(data: data, encoding: .utf8)
            {
                print(json)
            }
        } else {
            print(result.output)
        }

        let status = result.success ? "✅ Headless task completed" : "❌ Headless task failed"
        fputs("\n\(status) (\(result.stepsCount) steps)\n", stderr)
    }

    static func result(for thread: LaicaiThread?) -> HeadlessResult {
        let steps = thread?.steps ?? []
        return HeadlessResult(
            success: thread?.status == .completed,
            output: steps.last(where: { $0.kind == .textOutput })?.text ?? "",
            stepsCount: steps.count,
            toolCalls: steps.filter { $0.kind == .toolCall }.count,
            errors: steps.filter { $0.isFailure }.map { $0.text }
        )
    }

    static func exitCode(for result: HeadlessResult) -> Int32 {
        result.success ? 0 : 1
    }

    private func extractArgValue(_ flag: String) -> String? {
        guard let idx = CommandLine.arguments.firstIndex(of: flag),
            idx + 1 < CommandLine.arguments.count
        else { return nil }
        return CommandLine.arguments[idx + 1]
    }
}

struct HeadlessResult: Codable {
    var success: Bool
    var output: String
    var stepsCount: Int
    var toolCalls: Int
    var errors: [String]
}
