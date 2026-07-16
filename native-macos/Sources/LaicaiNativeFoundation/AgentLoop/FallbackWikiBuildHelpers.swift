import Foundation
import LaicaiNativeDomain

@MainActor
extension AgentLoop {
    private struct FallbackWikiBuildRequest {
        let tool: any LaicaiTool
        let topic: String
        let mode: String
        let source: FallbackWikiSource
        let taskContext: TaskContext
        var emitFailure: Bool = true
    }

    func runFallbackWikiBuildIfNeeded(
        message: String,
        taskContext: inout TaskContext,
        task: inout AgentTask,
        emitMissingMaterialFailure: Bool = false,
        onStep: @MainActor (TaskStep) -> Void
    ) async -> Bool? {
        guard Self.expectsWikiOutput(message),
            !Self.hasSavedWiki(in: task)
        else {
            return nil
        }

        guard let source = Self.fallbackWikiSource(message: message, taskContext: taskContext) else {
            guard emitMissingMaterialFailure else { return nil }
            let noMaterialStep = TaskStep(
                kind: .error,
                text: "Wiki会话没有可落盘的已读材料；请先读取或提取附件后继续。",
                isFailure: true,
                recoverable: true,
                retryAction: "继续处理"
            )
            task.steps.append(noMaterialStep)
            onStep(noMaterialStep)
            return false
        }

        guard isToolAllowed("wiki.build") else {
            let blockedStep = TaskStep(
                kind: .error,
                text: "Wiki会话必须保存笔记，但当前会话 工具权限不包含 wiki.build，无法完成落盘。",
                isFailure: true,
                recoverable: true,
                retryAction: "允许 wiki.build 后重试"
            )
            task.steps.append(blockedStep)
            onStep(blockedStep)
            return false
        }
        guard let wikiTool = toolRegistry.tool(named: "wiki_build") ?? toolRegistry.tool(named: "wiki.build") else {
            let missingStep = TaskStep(
                kind: .error,
                text: "Wiki会话必须保存笔记，但工具注册表中没有 wiki.build。",
                isFailure: true,
                recoverable: true
            )
            task.steps.append(missingStep)
            onStep(missingStep)
            return false
        }

        let gateStep = TaskStep(
            kind: .aiThinking,
            text: "编排层兜底：正在保存 Wiki 笔记。",
            isCollapsible: true,
            isCollapsed: true
        )
        task.steps.append(gateStep)
        onStep(gateStep)

        let topic = Self.fallbackWikiTopic(message: message, source: source)
        guard
            let atomicResult = await executeFallbackWikiBuild(
                FallbackWikiBuildRequest(
                    tool: wikiTool,
                    topic: topic,
                    mode: "atomic",
                    source: source,
                    taskContext: taskContext
                ),
                task: &task,
                onStep: onStep
            )
        else {
            return false
        }
        guard atomicResult.success else {
            return false
        }

        taskContext.memory.appendDecision("已保存 Wiki：\(topic)")

        if let mocResult = await executeFallbackWikiBuild(
            FallbackWikiBuildRequest(
                tool: wikiTool,
                topic: topic,
                mode: "moc",
                source: source,
                taskContext: taskContext,
                emitFailure: false
            ),
            task: &task,
            onStep: onStep
        ), mocResult.success {
            taskContext.memory.appendDecision("已保存 Wiki 索引：\(topic)")
        }

        let savedPath = atomicResult.data?["path"] ?? "02 Atomic/\(topic).md"
        let doneStep = TaskStep(
            kind: .textOutput,
            text: "已基于已提取材料保存 Wiki 笔记：\(topic) → \(savedPath)。",
            isCollapsible: false,
            isCollapsed: false
        )
        task.steps.append(doneStep)
        onStep(doneStep)
        return true
    }

    private func executeFallbackWikiBuild(
        _ request: FallbackWikiBuildRequest,
        task: inout AgentTask,
        onStep: @MainActor (TaskStep) -> Void
    ) async -> ToolResult? {
        let source = request.source
        let args: [String: Any] = [
            "topic": request.topic,
            "mode": request.mode,
            "save": true,
            "topK": 8,
            "sourceTitle": source.title,
            "sourcePath": source.path,
            "sourceText": String(source.text.prefix(40_000)),
        ]
        let argumentsJSON =
            (try? JSONSerialization.data(withJSONObject: args))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let params = Self.displayParamsFromJSON(argumentsJSON)
        let callId = "call_fallback_wiki_\(request.mode)_\(UUID().uuidString.prefix(8))"
        let callStep = TaskStep(
            kind: .toolCall,
            text: ToolStepFormatter.callText(toolName: "wiki.build", arguments: params),
            toolName: "wiki.build",
            toolParams: params,
            toolCallId: callId,
            isCollapsible: true,
            isCollapsed: true
        )
        task.steps.append(callStep)
        onStep(callStep)

        let (result, _) = await ValidationEngine.executeWithValidationJSON(
            tool: request.tool,
            argumentsJSON: argumentsJSON,
            context: request.taskContext,
            maxRetries: 1
        )
        if result.success || request.emitFailure {
            let resultText = ToolResultFormatter.displayText(
                toolName: "wiki.build",
                arguments: params,
                result: result
            )
            let resultStep = TaskStep(
                kind: .toolResult,
                text: resultText,
                toolName: "wiki.build",
                toolParams: params,
                toolCallId: callId,
                isCollapsible: true,
                isCollapsed: true,
                isFailure: !result.success
            )
            task.steps.append(resultStep)
            onStep(resultStep)
        }
        return result
    }

    private struct FallbackWikiSource {
        var path: String
        var title: String
        var text: String
    }

    private static func fallbackWikiSource(message: String, taskContext: TaskContext) -> FallbackWikiSource? {
        var candidates: [String] = []
        if let path = firstLocalPath(in: message) {
            candidates.append(path)
        }
        candidates.append(contentsOf: taskContext.memory.readFiles)
        candidates.append(contentsOf: taskContext.memory.fileContentCache.keys.sorted())

        var seen: Set<String> = []
        for rawPath in candidates {
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            let variants = [
                path,
                path.hasPrefix("/") ? path : (taskContext.workspaceRoot as NSString).appendingPathComponent(path),
            ]
            for variant in variants {
                guard let content = taskContext.memory.fileContentCache[variant] ?? taskContext.memory.fileContentCache[path] else {
                    continue
                }
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if path.hasPrefix("__thread_output_") {
                    let title = inferredTitle(from: trimmed) ?? "当前会话输出"
                    return FallbackWikiSource(
                        path: "current-thread-output",
                        title: title,
                        text: trimmed
                    )
                }
                if path.hasPrefix("web:") {
                    let title = inferredTitle(from: trimmed) ?? "已读取网页"
                    return FallbackWikiSource(
                        path: String(path.dropFirst("web:".count)),
                        title: title,
                        text: trimmed
                    )
                }
                return FallbackWikiSource(
                    path: variant,
                    title: URL(fileURLWithPath: variant).lastPathComponent,
                    text: trimmed
                )
            }
        }
        return nil
    }

    private static func fallbackWikiTopic(message: String, source: FallbackWikiSource) -> String {
        if source.path == "current-thread-output",
            let title = cleanFallbackTopic(source.title),
            title != "当前会话输出"
        {
            return title
        }
        let internalSourcePaths: Set<String> = ["current-thread-output"]
        let sourcePath = source.path
        if let path = firstLocalPath(in: message) ?? (sourcePath.isEmpty || internalSourcePaths.contains(sourcePath) ? nil : sourcePath) {
            let fileBase = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: #"[\s_-]?(20\d{2}|[01]?\d[0-3]?\d)$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !fileBase.isEmpty { return String(fileBase.prefix(80)) }
        }
        let compact =
            message
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .replacingOccurrences(of: "我觉得你的这个输出，需要", with: "")
            .replacingOccurrences(of: "这个输出", with: "")
            .replacingOccurrences(of: "当前输出", with: "")
            .replacingOccurrences(of: "整理到", with: "")
            .replacingOccurrences(of: "沉淀到", with: "")
            .replacingOccurrences(of: "沉淀", with: "")
            .replacingOccurrences(of: "保存到", with: "")
            .replacingOccurrences(of: "写进", with: "")
            .replacingOccurrences(of: "写入", with: "")
            .replacingOccurrences(of: "wiki", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "知识库", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let compact, let topic = cleanFallbackTopic(compact) {
            return topic
        }
        if let sourceTitle = cleanFallbackTopic(source.title) {
            return sourceTitle
        }
        return "整理资料"
    }

    private static func inferredTitle(from text: String) -> String? {
        let lines =
            text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for line in lines.prefix(20) {
            let stripped =
                line
                .replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^\*\*(.+)\*\*$"#, with: "$1", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " -:：`*"))
            guard stripped.count >= 4,
                stripped.count <= 80,
                !stripped.contains("```"),
                !stripped.hasPrefix("|"),
                !stripped.hasPrefix(">")
            else {
                continue
            }
            if stripped.contains("标题") || stripped.contains("清单") || stripped.contains("总结") || stripped.contains("方案")
                || stripped.contains("要点")
            {
                return stripped
            }
            if line.hasPrefix("#") {
                return stripped
            }
        }
        return nil
    }

    private static func cleanFallbackTopic(_ raw: String) -> String? {
        let cleaned =
            raw
            .replacingOccurrences(of: "标题可以叫", with: "")
            .replacingOccurrences(of: "标题", with: "")
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: " -:：`*")))
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(80))
    }

}
