import Foundation
import LaicaiNativeDomain

@MainActor
extension AgentLoop {
    func prepareTaskContext(_ context: TaskContext?, intent: UserIntent, message: String) -> TaskContext {
        var taskContext: TaskContext
        if let context {
            taskContext = context
        } else if intent == .chat {
            taskContext = AutoContextEngine.buildContext(
                workspaceRoot: config.workspaceRoot,
                userInput: message,
                fileLimit: 0
            )
        } else {
            taskContext = AutoContextEngine.buildContext(
                workspaceRoot: config.workspaceRoot,
                userInput: message
            )
        }
        taskContext.contextMode = config.contextMode

        if let vault = taskContext.vaultRoot, !vault.isEmpty, !WorkspaceSandbox.isOverlyBroadWorkspace(vault) {
            WorkspaceSandbox.shared.addAllowedPath(vault)
        }

        // Skip persistent memory load for pure chat (reduces startup latency)
        if intent != .chat || message.count > 100 {
            let persisted = TaskMemoryStore.load(workspaceRoot: config.workspaceRoot)
            if !persisted.isEmpty {
                taskContext.memory = TaskMemoryStore.merge(persisted, into: taskContext.memory)
            }
        }
        return taskContext
    }

    func authorizeUserPathsAndNarrowWorkspace(message: String, intent: UserIntent, taskContext: inout TaskContext) {
        guard intent != .chat else { return }

        let userPaths = Self.extractAbsolutePaths(from: message)
        var narrowedWorkspace = false
        for path in userPaths {
            var isDir: ObjCBool = false
            let dir: String
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                dir = path
            } else {
                dir = (path as NSString).deletingLastPathComponent
            }
            guard !dir.isEmpty && dir != "/" && !WorkspaceSandbox.isOverlyBroadWorkspace(dir) else { continue }
            WorkspaceSandbox.shared.addAllowedPath(dir)

            if !narrowedWorkspace {
                let currentRoot = taskContext.workspaceRoot
                let isBroad = currentRoot.isEmpty
                    || currentRoot == FileManager.default.homeDirectoryForCurrentUser.path
                    || (currentRoot.components(separatedBy: "/").count <= 4 && !dir.hasPrefix(currentRoot + "/"))
                if isBroad && FileManager.default.fileExists(atPath: dir) {
                    taskContext.workspaceRoot = dir
                    narrowedWorkspace = true
                }
            }
        }
    }

    func runPreparationTools(
        message: String,
        intent: UserIntent,
        needsPlanning: Bool,
        taskContext: inout TaskContext,
        task: inout AgentTask,
        onStep: @MainActor (TaskStep) -> Void
    ) async {
        await autoIndexWorkspaceIfNeeded(needsPlanning: needsPlanning, taskContext: &taskContext, task: &task, onStep: onStep)
        prefetchMentionedFilesIfNeeded(message: message, intent: intent, needsPlanning: needsPlanning, taskContext: &taskContext, task: &task, onStep: onStep)
    }

    private func autoIndexWorkspaceIfNeeded(
        needsPlanning: Bool,
        taskContext: inout TaskContext,
        task: inout AgentTask,
        onStep: @MainActor (TaskStep) -> Void
    ) async {
        guard needsPlanning, !taskContext.workspaceRoot.isEmpty, taskContext.memory.readFiles.isEmpty else {
            return
        }
        guard let indexTool = toolRegistry.tool(named: "workspace_index") ?? toolRegistry.tool(named: "workspace.index") else {
            return
        }

        let indexStep = TaskStep(
            kind: .toolCall,
            text: "编排层自动索引工作区",
            toolName: "workspace.index",
            isCollapsible: true,
            isCollapsed: true
        )
        task.steps.append(indexStep)
        onStep(indexStep)

        let indexResult = try? await indexTool.execute(argumentsJSON: "{}", context: taskContext)
        if let result = indexResult, result.success {
            let resultStep = TaskStep(
                kind: .toolResult,
                text: result.output,
                toolName: "workspace.index",
                isCollapsible: true,
                isCollapsed: true
            )
            task.steps.append(resultStep)
            onStep(resultStep)
            taskContext.memory.appendDecision("工作区索引：\(String(result.output.prefix(2000)))")
        }
    }

    private func prefetchMentionedFilesIfNeeded(
        message: String,
        intent: UserIntent,
        needsPlanning: Bool,
        taskContext: inout TaskContext,
        task: inout AgentTask,
        onStep: @MainActor (TaskStep) -> Void
    ) {
        guard intent != .chat && needsPlanning else { return }

        let readablePaths = Self.extractAbsolutePaths(from: message).compactMap { path -> String? in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
            return isDir.boolValue ? nil : path
        }
        guard !readablePaths.isEmpty else { return }

        let prefetchStep = TaskStep(
            kind: .aiThinking,
            text: "编排层预读 \(readablePaths.count) 个文件",
            isCollapsible: true,
            isCollapsed: true
        )
        task.steps.append(prefetchStep)
        onStep(prefetchStep)

        var prefetchedContent: [String] = []
        for path in readablePaths.prefix(5) {
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                let truncated = content.count > 8000 ? String(content.prefix(8000)) + "\n…（共\(content.count)字符）" : content
                taskContext.memory.readFiles.append(path)
                taskContext.memory.fileContentCache[path] = content
                let fileName = URL(fileURLWithPath: path).lastPathComponent
                prefetchedContent.append("### \(fileName)\n```\n\(truncated)\n```")
            }
        }
        if !prefetchedContent.isEmpty {
            taskContext.memory.appendDecision("预读文件内容：\n" + prefetchedContent.joined(separator: "\n\n"))
        }
    }
}
