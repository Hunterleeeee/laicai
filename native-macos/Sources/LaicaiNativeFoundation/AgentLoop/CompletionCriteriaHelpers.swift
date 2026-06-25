import Foundation
import LaicaiNativeDomain

@MainActor
extension AgentLoop {
    static func meetsCompletionCriteria(
        task: AgentTask,
        intent: UserIntent,
        didComplete: Bool,
        hadFailure: Bool,
        wasTruncated: Bool,
        isReadOnlyRun: Bool = false
    ) -> Bool {
        guard didComplete, !wasTruncated else { return false }
        let successfulResults = task.steps.filter { $0.kind == .toolResult && !$0.isFailure }
        let failedResults = task.steps.filter { $0.kind == .toolResult && $0.isFailure }
        let hasFinalOutput = task.steps.contains { $0.kind == .textOutput && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let message = task.steps.filter { $0.kind == .userInput }.map(\.text).joined(separator: "\n").lowercased()
        let hasWrite = Self.hasSuccessfulWrite(in: task)
        let hasSavedWiki = Self.hasSavedWiki(in: task)
        let expectsWikiOutput = Self.expectsWikiOutput(message)
        let riskPolicy = task.taskProtocol?.riskPolicy
        let hasEvidence = hasActionableEvidence(task: task, successfulResults: successfulResults)
            || task.steps.contains { $0.kind == .reviewRequest && $0.approved == true }
        let missingDeliverables = expectedDeliverablePaths(from: message, workspaceRoot: task.context.workspaceRoot).filter { path in
            var isDirectory: ObjCBool = false
            return !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) || isDirectory.boolValue
        }
        let hasUnrecoveredFailure = !failedResults.isEmpty && !Self.hasRecoveryAfterLastFailure(task)
        let hasVerificationFailure = task.steps.contains { $0.toolName == "verify.build" && $0.isFailure }
        let requiresUIEvidence = Self.expectsUIEvidence(message: message, protocolCriteria: task.taskProtocol?.completionCriteria ?? [])
        let hasUIEvidence = Self.hasUIEvidence(in: task)
        let requiresEvidence = intent != .chat
            && configRequiresEvidence(task: task, isReadOnlyRun: isReadOnlyRun)

        if riskPolicy == .dangerous {
            return false
        }
        if Self.hasSatisfiedImageGenerationRequest(task) {
            return !hasVerificationFailure
        }
        if !missingDeliverables.isEmpty && !isReadOnlyRun {
            return false
        }
        if requiresEvidence && !hasEvidence {
            return false
        }
        if requiresUIEvidence && !hasUIEvidence {
            return false
        }
        if riskPolicy == .inspect && hasWrite {
            return false
        }
        if task.taskProtocol != nil && task.taskProtocol?.isExecutable != true {
            return false
        }
        if expectsWikiOutput {
            return hasFinalOutput && hasSavedWiki && !hasUnrecoveredFailure
        }
        if hasUnrecoveredFailure && !isReadOnlyRun {
            return false
        }

        switch intent {
        case .chat:
            // Chat: text output is sufficient
            return hasFinalOutput
        case .research:
            // Research: text output + any evidence of research activity
            let hasSearch = task.steps.contains { $0.kind == .toolCall && $0.toolName == "web.search" }
            let hasFetch = task.steps.contains { $0.kind == .toolCall && $0.toolName == "web.fetch" }
            return hasFinalOutput && (hasSearch || hasFetch || hasEvidence)
        case .task, .workflow:
            if isReadOnlyRun {
                // Read-only task: text output is sufficient
                return hasFinalOutput
            }
            if hasVerificationFailure { return false }
            if expectsOfficeDocumentDelivery(message), hasSuccessfulDocumentWrite(in: task) {
                return hasFinalOutput && hasSatisfiedDocumentDelivery(in: task, originalMessage: message)
            }
            if hadFailure && failedResults.count >= successfulResults.count && !hasRecoveryAfterLastFailure(task) { return false }
            if hasWrite {
                // Write task: either final output or successful file changes
                return hasFinalOutput || successfulResults.contains { isFileChangeTool($0.toolName ?? "") }
            }
            // Default: text output + some evidence
            return hasFinalOutput && (hasEvidence || !requiresEvidence)
        }
    }

    private static func hasActionableEvidence(task: AgentTask, successfulResults: [TaskStep]) -> Bool {
        if !successfulResults.isEmpty {
            return true
        }
        guard let ledger = task.executionLedger else {
            return false
        }
        if !ledger.readFiles.isEmpty || !ledger.searches.isEmpty || !ledger.modifiedFiles.isEmpty || !ledger.commands.isEmpty || !ledger.verification.isEmpty {
            return true
        }
        return ledger.pages.contains { page in
            let lower = page.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("file://") {
                return true
            }
            if page.hasPrefix("/") {
                if WorkspaceSandbox.isOverlyBroadWorkspace(page) || WorkspaceSandbox.isDisposableSmokeWorkspace(page) {
                    return false
                }
                return true
            }
            return lower.contains("screenshot") || lower.contains("accessibility") || lower.contains(".png") || lower.contains(".jpg")
        }
    }

    private static func configRequiresEvidence(task: AgentTask, isReadOnlyRun: Bool) -> Bool {
        if let policy = task.taskProtocol?.riskPolicy {
            return policy != .ask
        }
        guard !task.context.workspaceRoot.isEmpty else { return false }
        let message = task.steps
            .filter { $0.kind == .userInput }
            .map(\.text)
            .joined(separator: "\n")
            .lowercased()
        let evidenceMarkers = [
            "项目", "代码", "文件", "工作区", "仓库", "repo", "repository",
            "页面", "按钮", "bug", "报错", "异常", "卡顿", "卡死", "性能",
            "优化", "修复", "调整", "改进", "实现", "创建", "修改", "读取",
            "查看", "检查", "排查", "诊断", "不生效", "测试", "构建", "编译",
            "workspace", "code", "file", "bug", "error", "fix", "implement", "optimize", "performance", "test", "build"
        ]
        return evidenceMarkers.contains { message.contains($0) } || expectsWriteOutput(message) || isReadOnlyRun
    }

    static func hasRecoveryAfterLastFailure(_ task: AgentTask) -> Bool {
        guard let lastFailureIndex = task.steps.lastIndex(where: { $0.kind == .toolResult && $0.isFailure }) else {
            return false
        }
        let later = task.steps.dropFirst(lastFailureIndex + 1)
        return later.contains { step in
            if step.kind == .toolResult, !step.isFailure {
                let recoveryTools: Set<String> = ["file.extract", "document.transform", "file.read", "wiki.build", "file.write", "file.edit", "diff.apply", "workspace.index", "code.search", "shell.exec", "web.fetch", "web.search"]
                return recoveryTools.contains(step.toolName ?? "")
            }
            if step.kind == .reviewRequest, step.approved == true {
                return true
            }
            return false
        }
    }

    nonisolated static func expectsUIEvidence(message: String, protocolCriteria: [String] = []) -> Bool {
        let haystack = ([message] + protocolCriteria).joined(separator: "\n").lowercased()
        let markers = [
            "ui", "页面", "界面", "按钮", "窗口", "截图", "可访问性", "accessibility",
            "browser", "浏览器", "前端", "视觉", "布局", "样式", "点击", "scroll", "滚动"
        ]
        return markers.contains { haystack.contains($0.lowercased()) }
    }

    nonisolated static func hasUIEvidence(in task: AgentTask) -> Bool {
        if task.executionLedger?.pages.contains(where: { page in
            let lower = page.lowercased()
            return lower.contains("screenshot")
                || lower.contains(".png")
                || lower.contains("accessibility")
                || lower.hasPrefix("http://")
                || lower.hasPrefix("https://")
                || lower.hasPrefix("file://")
        }) == true {
            return true
        }
        return task.steps.contains { step in
            let tool = step.toolName ?? ""
            let action = step.toolParams?["action"]?.lowercased() ?? ""
            let text = step.text.lowercased()
            guard step.kind == .toolResult || step.kind == .toolCall else { return false }
            if ["browser", "browser.real", "computer"].contains(tool) {
                if action == "screenshot" || action == "extract" || action == "windows" || action == "frontmost" {
                    return !step.isFailure
                }
                if text.contains("截图") || text.contains("页面") || text.contains("窗口") || text.contains("accessibility") {
                    return !step.isFailure
                }
            }
            if tool == "web.fetch" && !step.isFailure {
                return true
            }
            return false
        }
    }

    nonisolated static func resultStepParams(toolName: String, arguments: [String: String], result: ToolResult) -> [String: String] {
        let canonical = ToolNameCodec.canonicalName(toolName)
        guard ["image.generate", "document.transform"].contains(canonical), let data = result.data else {
            return arguments
        }
        return arguments.merging(data) { _, resultValue in resultValue }
    }

    nonisolated static func hasSuccessfulWrite(in task: AgentTask) -> Bool {
        return task.steps.contains { step in
            if isSuccessfulDocumentWrite(step) { return true }
            guard isFileChangeTool(step.toolName ?? "") else { return false }
            if step.kind == .reviewRequest, step.approved == true { return true }
            return step.kind == .toolResult && !step.isFailure
        }
    }

    nonisolated static func isSuccessfulDocumentWrite(_ step: TaskStep) -> Bool {
        guard step.kind == .toolResult,
              step.toolName == "document.transform",
              !step.isFailure else { return false }
        let action = step.toolParams?["action"] ?? ""
        guard ["apply", "copy", "render"].contains(action) else { return false }
        let path: String?
        if action == "render" {
            path = step.toolParams?["pdfPath"] ?? step.toolParams?["outputPath"] ?? step.toolParams?["path"]
        } else {
            path = step.toolParams?["outputPath"] ?? step.toolParams?["path"]
        }
        guard let path, !path.isEmpty else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    nonisolated static func hasSuccessfulDocumentWrite(in task: AgentTask) -> Bool {
        task.steps.contains { isSuccessfulDocumentWrite($0) }
    }

    nonisolated static func expectsOfficeDocumentDelivery(_ message: String) -> Bool {
        guard messageContainsDeliverableIntent(message) else { return false }
        let paths = extractAbsolutePaths(from: message)
        return paths.contains { ["pptx", "docx", "xlsx", "xlsm"].contains(($0 as NSString).pathExtension.lowercased()) }
    }

    nonisolated static func hasSatisfiedDocumentDelivery(in task: AgentTask, originalMessage: String) -> Bool {
        let writes = task.steps.filter { isSuccessfulDocumentWrite($0) }
        guard !writes.isEmpty else { return false }

        let expectsTranslation = originalMessage.contains("翻译")
            || originalMessage.contains("英文")
            || originalMessage.localizedCaseInsensitiveContains("english")
        guard expectsTranslation else { return true }

        let verifyResults = task.steps.filter {
            $0.kind == .toolResult
                && $0.toolName == "document.transform"
                && !$0.isFailure
                && $0.toolParams?["action"] == "verify"
        }
        guard let latestVerify = verifyResults.last else { return false }
        if latestVerify.toolParams?["complete"] == "true" { return true }
        if let remaining = latestVerify.toolParams?["remainingCJK"].flatMap(Int.init) {
            return remaining == 0
        }
        return false
    }

    static func hasSatisfiedImageGenerationRequest(_ task: AgentTask) -> Bool {
        let message = task.steps
            .filter { $0.kind == .userInput }
            .map(\.text)
            .joined(separator: "\n")
        guard expectsImageGeneration(message) else { return false }
        guard let deliveredIndex = task.steps.firstIndex(where: { isSuccessfulGeneratedImageResult($0) }) else { return false }
        let laterFailures = task.steps.dropFirst(deliveredIndex + 1).filter { $0.kind == .toolResult && $0.isFailure }
        return laterFailures.allSatisfy { $0.toolName == "image.generate" }
    }

    static func isSuccessfulGeneratedImageResult(_ step: TaskStep) -> Bool {
        guard step.kind == .toolResult, step.toolName == "image.generate", !step.isFailure else { return false }
        if let path = step.toolParams?["imagePath"], !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return step.text.contains("图片已生成") || step.text.contains("生成图片：")
    }

    static func expectsImageGeneration(_ message: String) -> Bool {
        RoutingTextHeuristics.requestsImageGeneration(message)
    }

    static func hasSavedWiki(in task: AgentTask) -> Bool {
        task.steps.contains { step in
            step.kind == .toolResult
                && step.toolName == "wiki.build"
                && !step.isFailure
                && (step.toolParams?["save"] == "true" || step.text.contains("已保存 Wiki"))
        }
    }

    static func needsWikiSaveNudge(message: String, task: AgentTask, isReadOnlyRun: Bool, hasWritten: Bool) -> Bool {
        expectsWikiOutput(message)
            && !isReadOnlyRun
            && !hasSavedWiki(in: task)
    }

    static func completionQualityIssues(
        task: AgentTask,
        message: String,
        workspaceRoot: String,
        hasWritten: Bool,
        expectsWiki: Bool
    ) -> [String] {
        var issues: [String] = []
        let failedWrites = task.steps.filter { $0.kind == .toolResult && $0.isFailure == true && isFileChangeTool($0.toolName ?? "") }
        if !failedWrites.isEmpty {
            issues.append("有 \(failedWrites.count) 次文件写入失败")
        }

        let wroteCode = task.steps.contains { step in
            guard step.kind == .toolCall, isFileChangeTool(step.toolName ?? "") else { return false }
            let codeExts: Set<String> = ["swift", "py", "js", "ts", "tsx", "jsx", "rs", "go", "java", "c", "cpp", "h", "m", "mm"]
            if step.toolName == "document.transform" { return false }
            return codeExts.contains((pathForFileChange(callStep: step) as NSString).pathExtension.lowercased())
        }
        let hadVerify = task.steps.contains { $0.kind == .toolCall && $0.toolName == "verify.build" }
        if wroteCode && !hadVerify && ValidationEngine.suggestVerificationCommand(workspaceRoot: workspaceRoot) != nil {
            issues.append("写了代码但没有 verify_build 验证编译")
        }

        let lower = message.lowercased()
        let expectsWrite = lower.contains("创建") || lower.contains("写入") || lower.contains("新建") || lower.contains("修改") || lower.contains("修复")
        if expectsWrite && !hasWritten {
            issues.append("用户要求创建/修改文件，但没有任何写入操作")
        }
        let missingDeliverables = expectedDeliverablePaths(from: message, workspaceRoot: workspaceRoot).filter { path in
            var isDirectory: ObjCBool = false
            return !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) || isDirectory.boolValue
        }
        if !missingDeliverables.isEmpty {
            let names = missingDeliverables.prefix(3).map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "、")
            issues.append("用户要求交付的目标文件尚未生成：\(names)")
        }
        if expectsWiki && !hasSavedWiki(in: task) {
            issues.append("用户要求整理到 Wiki/知识库，但没有保存任何 Wiki 笔记")
        }
        return issues
    }

    static func expectedDeliverablePaths(from message: String, workspaceRoot: String) -> [String] {
        guard messageContainsDeliverableIntent(message) else { return [] }
        var paths = explicitDeliverablePaths(from: message)
        paths.append(contentsOf: inferredDesktopDeliverables(from: message))
        var seen: Set<String> = []
        return paths.compactMap { raw in
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            let absolute = path.hasPrefix("/")
                ? path
                : (workspaceRoot.isEmpty ? path : (workspaceRoot as NSString).appendingPathComponent(path))
            guard likelyDeliverablePath(absolute), seen.insert(absolute).inserted else { return nil }
            return absolute
        }
    }

    nonisolated private static func messageContainsDeliverableIntent(_ message: String) -> Bool {
        let markers = ["输出", "导出", "保存", "存到", "放到", "生成", "创建", "副本", "转化", "转换", "翻译"]
        return markers.contains { message.localizedCaseInsensitiveContains($0) }
    }

    private static func likelyDeliverablePath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        let deliverableExts: Set<String> = [
            "pptx", "ppt", "pdf", "docx", "xlsx", "csv", "txt", "md", "json",
            "png", "jpg", "jpeg", "webp", "html", "zip"
        ]
        return deliverableExts.contains(ext)
    }

    private static func explicitDeliverablePaths(from message: String) -> [String] {
        extractAbsolutePaths(from: message).filter { path in
            let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            if name.contains("_english") || name.contains("_en.") || name.contains("english") || name.contains("英文") {
                return true
            }
            guard let range = message.range(of: path) else { return false }
            let prefix = String(message[..<range.lowerBound].suffix(24))
            let markers = ["输出", "导出", "保存", "存到", "放到", "生成", "创建", "副本", "写到"]
            return markers.contains { prefix.contains($0) }
        }
    }

    private static func inferredDesktopDeliverables(from message: String) -> [String] {
        guard message.contains("桌面") || message.localizedCaseInsensitiveContains("desktop") else { return [] }

        let explicitNamePatterns = [
            #"([^\s\n，。；;：:「」"'`]+(?:_English|_EN)[^\s\n，。；;：:「」"'`]*)"#,
            #"([^\s\n，。；;：:「」"'`]*(?:英文版|English|EN)[^\s\n，。；;：:「」"'`]*)"#
        ]
        for pattern in explicitNamePatterns {
            if let match = firstDeliverableName(in: message, pattern: pattern) {
                return [desktopPath(fileName: match)]
            }
        }

        guard (message.contains("英文") || message.localizedCaseInsensitiveContains("english")),
              let sourcePath = extractAbsolutePaths(from: message).first(where: { likelyDeliverablePath($0) }) else {
            return []
        }
        let url = URL(fileURLWithPath: sourcePath)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        guard !base.isEmpty, !ext.isEmpty else { return [] }
        return [
            desktopPath(fileName: "\(base)_English.\(ext)"),
            desktopPath(fileName: "\(base)_EN.\(ext)")
        ]
    }

    private static func firstDeliverableName(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard match.numberOfRanges > 1,
                  let swiftRange = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[swiftRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: "。，、；;：:）)]}>\"'`"))
            guard likelyDeliverablePath(name), !name.contains("/") else { continue }
            return name
        }
        return nil
    }

    private static func desktopPath(fileName: String) -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/\(fileName)")
    }

}
