import Foundation
import LaicaiNativeDomain

// MARK: - Skill Composition — pipe 式技能组合 + workflow chain + 批量执行

/// A pipeline of skills that execute sequentially, passing output from one to the next.
public struct SkillPipeline: Codable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var steps: [PipelineStep]
    public var status: PipelineStatus
    public var createdAt: Date
    public var completedAt: Date?
    public var batchInput: [String]?

    public init(
        name: String,
        steps: [PipelineStep],
        batchInput: [String]? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.steps = steps
        self.status = .pending
        self.createdAt = Date()
        self.batchInput = batchInput
    }
}

public struct PipelineStep: Codable, Sendable, Identifiable {
    public let id: UUID
    public var skillName: String
    public var workflowName: String?
    public var message: String
    public var inputTransform: InputTransform
    public var status: PipelineStepStatus
    public var output: String?
    public var error: String?
    public var startedAt: Date?
    public var completedAt: Date?

    public init(
        skillName: String,
        workflowName: String? = nil,
        message: String = "",
        inputTransform: InputTransform = .passthrough
    ) {
        self.id = UUID()
        self.skillName = skillName
        self.workflowName = workflowName
        self.message = message
        self.inputTransform = inputTransform
        self.status = .pending
    }
}

public enum PipelineStatus: String, Codable, Sendable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

public enum PipelineStepStatus: String, Codable, Sendable {
    case pending
    case running
    case completed
    case failed
    case skipped
}

/// How to transform the previous step's output into the next step's input
public enum InputTransform: Codable, Sendable {
    case passthrough          // Use previous output as-is
    case template(String)     // Template with {{input}} placeholder
    case jsonPath(String)     // Extract field from JSON output
    case lineByLine           // Split into lines for batch processing

    private enum CodingKeys: String, CodingKey { case type, value }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .passthrough:
            try c.encode("passthrough", forKey: .type)
        case .template(let t):
            try c.encode("template", forKey: .type)
            try c.encode(t, forKey: .value)
        case .jsonPath(let p):
            try c.encode("jsonPath", forKey: .type)
            try c.encode(p, forKey: .value)
        case .lineByLine:
            try c.encode("lineByLine", forKey: .type)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "template":
            self = .template(try c.decode(String.self, forKey: .value))
        case "jsonPath":
            self = .jsonPath(try c.decode(String.self, forKey: .value))
        case "lineByLine":
            self = .lineByLine
        default:
            self = .passthrough
        }
    }
}

// MARK: - Pipeline Parser

/// Parse pipe-style skill composition: "review PR | fix issues | add tests"
public struct PipelineParser {
    public static func parse(_ input: String) -> SkillPipeline? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Pipe syntax: "skill1 | skill2 | skill3"
        let segments = trimmed.components(separatedBy: " | ")
        guard segments.count >= 2 else { return nil }

        let steps = segments.map { segment -> PipelineStep in
            let cleaned = segment.trimmingCharacters(in: .whitespaces)
            // Try to match skill name from known skills
            return PipelineStep(
                skillName: cleaned,
                message: cleaned,
                inputTransform: .passthrough
            )
        }

        let name = segments.map { $0.trimmingCharacters(in: .whitespaces).prefix(15) }.joined(separator: " → ")
        return SkillPipeline(name: String(name), steps: steps)
    }

    /// Parse batch input: "foreach file in *.swift: review code"
    public static func parseBatch(_ input: String) -> SkillPipeline? {
        // Pattern: foreach <var> in <glob>: <message>
        let pattern = #"^foreach\s+\w+\s+in\s+(.+?):\s*(.+)$"#
        guard let match = input.range(of: pattern, options: .regularExpression) else { return nil }

        let text = String(input[match])
        let colonIndex = text.firstIndex(of: ":")!
        let glob = String(text[text.index(text.startIndex, offsetBy: text.range(of: " in ")!.upperBound.utf16Offset(in: text))..<colonIndex])
            .trimmingCharacters(in: .whitespaces)
        let message = String(text[text.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)

        let step = PipelineStep(
            skillName: message,
            message: message,
            inputTransform: .lineByLine
        )

        return SkillPipeline(
            name: "批量：\(message)",
            steps: [step],
            batchInput: [glob]
        )
    }
}

// MARK: - Composition Engine

@MainActor
public final class SkillCompositionEngine: ObservableObject {
    public static let shared = SkillCompositionEngine()

    @Published public private(set) var activePipelines: [SkillPipeline] = []
    @Published public private(set) var history: [SkillPipeline] = []

    /// Callback: execute a single skill step. Returns (output, success).
    public var onExecuteStep: (@Sendable (String, String?) async -> (String, Bool))?

    /// Callback: expand a glob pattern to file list.
    public var onExpandGlob: (@Sendable (String, String) async -> [String])?

    private init() {}

    /// Execute a pipeline sequentially
    public func execute(_ pipeline: SkillPipeline, workspaceRoot: String) async {
        var pipe = pipeline
        pipe.status = .running
        activePipelines.append(pipe)
        updatePipeline(pipe)

        var currentInput: String = ""

        // Handle batch mode
        if let batchInput = pipe.batchInput, let glob = batchInput.first {
            let files = await onExpandGlob?(glob, workspaceRoot) ?? []
            if files.isEmpty {
                pipe.status = .failed
                updatePipeline(pipe)
                moveToDone(pipe)
                return
            }

            for file in files {
                for stepIdx in pipe.steps.indices {
                    pipe.steps[stepIdx].status = .running
                    pipe.steps[stepIdx].startedAt = Date()
                    updatePipeline(pipe)

                    let message = pipe.steps[stepIdx].message
                        .replacingOccurrences(of: "{{file}}", with: file)
                        .replacingOccurrences(of: "{{input}}", with: file)

                    let (output, success) = await onExecuteStep?(message, nil) ?? ("", false)

                    pipe.steps[stepIdx].output = String(output.prefix(2000))
                    pipe.steps[stepIdx].status = success ? .completed : .failed
                    pipe.steps[stepIdx].completedAt = Date()
                    updatePipeline(pipe)

                    guard success else {
                        pipe.status = .failed
                        updatePipeline(pipe)
                        moveToDone(pipe)
                        return
                    }
                }
            }

            pipe.status = .completed
            pipe.completedAt = Date()
            updatePipeline(pipe)
            moveToDone(pipe)
            return
        }

        // Sequential pipeline
        for stepIdx in pipe.steps.indices {
            guard pipe.status == .running else { break }

            pipe.steps[stepIdx].status = .running
            pipe.steps[stepIdx].startedAt = Date()
            updatePipeline(pipe)

            let transformedInput = applyTransform(pipe.steps[stepIdx].inputTransform, input: currentInput)
            let message: String
            if transformedInput.isEmpty {
                message = pipe.steps[stepIdx].message
            } else {
                message = pipe.steps[stepIdx].message.isEmpty
                    ? transformedInput
                    : "\(pipe.steps[stepIdx].message)\n\n上一步输出：\n\(transformedInput)"
            }

            let skillName = pipe.steps[stepIdx].skillName
            let (output, success) = await onExecuteStep?(message, skillName) ?? ("", false)

            pipe.steps[stepIdx].output = String(output.prefix(2000))
            pipe.steps[stepIdx].status = success ? .completed : .failed
            pipe.steps[stepIdx].completedAt = Date()
            updatePipeline(pipe)

            guard success else {
                pipe.status = .failed
                updatePipeline(pipe)
                moveToDone(pipe)
                return
            }

            currentInput = output
        }

        pipe.status = .completed
        pipe.completedAt = Date()
        updatePipeline(pipe)
        moveToDone(pipe)
    }

    public func cancel(id: UUID) {
        guard let idx = activePipelines.firstIndex(where: { $0.id == id }) else { return }
        activePipelines[idx].status = .cancelled
        moveToDone(activePipelines[idx])
    }

    // MARK: - Helpers

    private func applyTransform(_ transform: InputTransform, input: String) -> String {
        switch transform {
        case .passthrough:
            return input
        case .template(let t):
            return t.replacingOccurrences(of: "{{input}}", with: input)
        case .jsonPath(let path):
            // Simple top-level key extraction
            guard let data = input.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = json[path] else { return input }
            if let str = value as? String { return str }
            return "\(value)"
        case .lineByLine:
            return input // Handled at batch level
        }
    }

    private func updatePipeline(_ pipeline: SkillPipeline) {
        if let idx = activePipelines.firstIndex(where: { $0.id == pipeline.id }) {
            activePipelines[idx] = pipeline
        }
    }

    private func moveToDone(_ pipeline: SkillPipeline) {
        activePipelines.removeAll { $0.id == pipeline.id }
        history.insert(pipeline, at: 0)
        if history.count > 50 { history = Array(history.prefix(50)) }
    }
}

// MARK: - Workflow Chain

/// Chain multiple workflows together: output of workflow A feeds into workflow B
public struct WorkflowChain: Codable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var workflowNames: [String]
    public var paramMapping: [String: String] // "workflow2.input" -> "workflow1.output"

    public init(name: String, workflowNames: [String], paramMapping: [String: String] = [:]) {
        self.id = UUID()
        self.name = name
        self.workflowNames = workflowNames
        self.paramMapping = paramMapping
    }
}

/// Registry and persistence for workflow chains
@MainActor
public final class WorkflowChainRegistry: ObservableObject {
    public static let shared = WorkflowChainRegistry()

    @Published public private(set) var chains: [WorkflowChain] = []

    private init() {}

    public func load(workspaceRoot: String) {
        let path = (workspaceRoot as NSString).appendingPathComponent(".laicai/chains.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let decoded = try? JSONDecoder().decode([WorkflowChain].self, from: data) else { return }
        chains = decoded
    }

    public func save(workspaceRoot: String) {
        let dir = (workspaceRoot as NSString).appendingPathComponent(".laicai")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("chains.json")
        guard let data = try? JSONEncoder().encode(chains) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public func addChain(_ chain: WorkflowChain) {
        chains.append(chain)
    }

    public func removeChain(id: UUID) {
        chains.removeAll { $0.id == id }
    }
}
