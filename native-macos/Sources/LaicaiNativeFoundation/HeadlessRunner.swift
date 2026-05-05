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
        guard isHeadless, let prompt = taskPrompt, !prompt.isEmpty else { return false }

        if let ws = workspace, !ws.isEmpty {
            store.updateWorkspacePath(ws)
        }
        if let cn = connectorName, !cn.isEmpty {
            if let connector = store.state.connectors.first(where: { $0.name == cn }) {
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

        // Monitor task completion
        Task { @MainActor in
            while store.state.isGenerating {
                try? await Task.sleep(for: .seconds(1))

                // Auto-approve pending reviews in headless mode
                if autoApprove {
                    for thread in store.state.threads {
                        for step in thread.steps where step.kind == .reviewRequest && step.approved == nil {
                            store.approveReview(taskID: thread.id, stepID: step.id)
                            fputs("  ✅ Auto-approved review: \(step.diffFilePath ?? "unknown")\n", stderr)
                        }
                    }
                }
            }

            // Output results
            let lastThread = store.state.threads.sorted(by: { $0.updatedAt > $1.updatedAt }).first
            let steps = lastThread?.steps ?? []
            let finalOutput = steps.last(where: { $0.kind == .textOutput })?.text ?? ""

            if outputFormat == "json" {
                let result = HeadlessResult(
                    success: lastThread?.status == .completed,
                    output: finalOutput,
                    stepsCount: steps.count,
                    toolCalls: steps.filter { $0.kind == .toolCall }.count,
                    errors: steps.filter { $0.isFailure }.map { $0.text }
                )
                if let data = try? JSONEncoder().encode(result),
                   let json = String(data: data, encoding: .utf8) {
                    print(json)
                }
            } else {
                print(finalOutput)
            }

            fputs("\n✅ Headless task completed (\(steps.count) steps)\n", stderr)
            exit(0)
        }

        return true
    }

    private func extractArgValue(_ flag: String) -> String? {
        guard let idx = CommandLine.arguments.firstIndex(of: flag),
              idx + 1 < CommandLine.arguments.count else { return nil }
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
