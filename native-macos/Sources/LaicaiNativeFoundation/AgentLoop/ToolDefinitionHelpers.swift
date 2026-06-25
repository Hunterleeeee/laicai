import Foundation
import LaicaiNativeDomain

@MainActor
extension AgentLoop {
    // Cache for tool definitions keyed by (intent, phase)
    private static var toolDefCache: [String: [ToolDefinition]] = [:]
    private static var lastRegistryCount: Int = 0

    public static func toolDefinitions(for intent: UserIntent, phase: TaskPhase = .explore, registry: ToolRegistry? = nil) -> [ToolDefinition] {
        let currentRegistry = registry ?? .shared
        let cacheKey = "\(intent)-\(phase)"

        // Invalidate cache if registry changed
        let currentCount = currentRegistry.toolDefinitions.count
        if currentCount != lastRegistryCount {
            toolDefCache.removeAll()
            lastRegistryCount = currentCount
        }

        // Return cached if available
        if let cached = toolDefCache[cacheKey] {
            return cached
        }

        let allDefs = currentRegistry.toolDefinitions
        let phaseDefs: [ToolDefinition]
        switch intent {
        case .chat:
            // Chat gets basic read-only tools so the agent can gather context
            // when needed, without risking mutations.
            let allowed: Set<String> = [
                "file.read", "file.extract", "code.search", "workspace.index",
                "web.search", "web.fetch"
            ]
            phaseDefs = allDefs.filter { def in
                allowed.contains(ToolNameCodec.canonicalName(def.function.name))
            }
        case .research:
            let allowed: Set<String> = [
                "web.search", "web.fetch", "file.read", "file.extract", "document.transform",
                "code.search", "workspace.index"
            ]
            phaseDefs = allDefs.filter { def in
                allowed.contains(ToolNameCodec.canonicalName(def.function.name))
            }
        case .task, .workflow:
            let allowed = phase.allowedTools
            phaseDefs = allDefs.filter { def in
                let canonical = ToolNameCodec.canonicalName(def.function.name)
                return allowed.contains(canonical)
            }
        }
        let result = phaseDefs.sorted { lhs, rhs in
            let lhsPriority = toolPriority(lhs.function.name, intent: intent, phase: phase)
            let rhsPriority = toolPriority(rhs.function.name, intent: intent, phase: phase)
            if lhsPriority == rhsPriority {
                return lhs.function.name < rhs.function.name
            }
            return lhsPriority < rhsPriority
        }

        // Cache the result
        toolDefCache[cacheKey] = result
        return result
    }

    private static func toolPriority(_ name: String, intent: UserIntent, phase: TaskPhase) -> Int {
        let canonical = ToolNameCodec.canonicalName(name)
        switch intent {
        case .research:
            return [
                "web.search": 0,
                "web.fetch": 1,
                "file.read": 2,
                "file.extract": 3,
                "code.search": 4,
                "workspace.index": 5
            ][canonical] ?? 20
        case .chat:
            return [
                "file.read": 0,
                "file.extract": 1,
                "document.transform": 2,
                "code.search": 3,
                "web.search": 4,
                "web.fetch": 5,
                "workspace.index": 6
            ][canonical] ?? 20
        case .task, .workflow:
            let base: [String: Int]
            switch phase {
            case .explore:
                base = [
                    "workspace.index": 0,
                    "code.search": 1,
                    "file.read": 2,
                    "file.extract": 3,
                    "document.transform": 4,
                    "web.search": 5,
                    "web.fetch": 6,
                    "wiki.build": 7
                ]
            case .execute:
                base = [
                    "file.edit": 0,
                    "file.write": 1,
                    "document.transform": 2,
                    "diff.apply": 3,
                    "shell.exec": 4,
                    "file.read": 5,
                    "file.extract": 6,
                    "code.search": 7,
                    "wiki.build": 8,
                    "web.fetch": 9,
                    "web.search": 10,
                    "skill.manage": 11
                ]
            case .verify:
                base = [
                    "verify.build": 0,
                    "shell.exec": 1,
                    "document.transform": 2,
                    "file.read": 3,
                    "file.extract": 4,
                    "code.search": 5,
                    "file.edit": 6,
                    "diff.apply": 7,
                    "skill.manage": 8,
                    "git": 9
                ]
            case .summarize:
                base = [
                    "git": 0,
                    "skill.manage": 1,
                    "file.read": 2,
                    "file.extract": 3,
                    "document.transform": 4,
                    "verify.build": 5,
                    "code.search": 6
                ]
            }
            return base[canonical] ?? 20
        }
    }

    /// Infer current task phase from accumulated steps.
    nonisolated public static func inferPhase(from steps: [TaskStep]) -> TaskPhase {
        // Explicit state machine for phase transitions
        // Transitions: explore → execute → verify → summarize

        // Check for final output after verify (summarize phase)
        let hasVerifyCheck = steps.contains { $0.kind == .aiThinking && $0.text.hasPrefix("完成检查") }
        let hasFinalOutput = steps.last?.kind == .textOutput && hasVerifyCheck
        if hasFinalOutput { return .summarize }

        // Check for verify indicators
        let hasBuildVerify = steps.contains { $0.toolName == "verify.build" && $0.kind == .toolResult }
        let hasCompletionCheck = steps.contains { $0.kind == .aiThinking && ($0.text.contains("完成检查") || $0.text.contains("验证")) }
        if hasBuildVerify || hasCompletionCheck { return .verify }

        // Check for write/mutation operations (execute phase)
        let hasWrite = steps.contains { step in
            isFileChangeTool(step.toolName ?? "") || isSuccessfulDocumentWrite(step)
        }
        let hasShellExec = steps.contains { $0.toolName == "shell.exec" && $0.kind == .toolResult && !$0.isFailure }
        if hasWrite || hasShellExec { return .execute }

        // Check for sufficient exploration (execute phase)
        let readCount = steps.filter { $0.toolName == "file.read" && $0.kind == .toolResult && !$0.isFailure }.count
        let searchCount = steps.filter { $0.toolName == "code.search" && $0.kind == .toolCall }.count
        let fetchCount = steps.filter { $0.toolName == "web.fetch" && $0.kind == .toolResult && !$0.isFailure }.count
        let explorationCount = readCount + searchCount + fetchCount
        if explorationCount >= 3 { return .execute }

        // Default: explore
        return .explore
    }
}
