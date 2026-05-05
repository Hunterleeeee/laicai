// 来财 CLI — 独立终端 Agent
// 直接在终端运行 AgentLoop，不依赖桌面 App
//
// 用法：
//   laicai "review this PR"              — 单次任务
//   laicai -i                            — 交互式 REPL
//   echo "hello" | laicai "翻译"          — pipe 输入
//   laicai --model claude-3.5-sonnet     — 指定模型
//   laicai --endpoint https://api.xxx    — 指定 API
//   laicai --help                        — 帮助

import Foundation
import LaicaiNativeDomain
import LaicaiNativeFoundation

// MARK: - ANSI Terminal Colors

enum Term {
    static let reset   = "\u{001B}[0m"
    static let bold    = "\u{001B}[1m"
    static let dim     = "\u{001B}[2m"
    static let italic  = "\u{001B}[3m"
    static let red     = "\u{001B}[31m"
    static let green   = "\u{001B}[32m"
    static let yellow  = "\u{001B}[33m"
    static let blue    = "\u{001B}[34m"
    static let magenta = "\u{001B}[35m"
    static let cyan    = "\u{001B}[36m"
    static let gray    = "\u{001B}[90m"
    static let white   = "\u{001B}[37m"

    static let bgRed    = "\u{001B}[41m"
    static let bgGreen  = "\u{001B}[42m"
    static let bgYellow = "\u{001B}[43m"
    static let bgBlue   = "\u{001B}[44m"

    static func colored(_ text: String, _ color: String) -> String {
        "\(color)\(text)\(reset)"
    }

    static func header(_ text: String) -> String {
        "\(bold)\(cyan)╭─ \(text)\(reset)"
    }

    static func footer(_ text: String) -> String {
        "\(dim)\(cyan)╰─ \(text)\(reset)"
    }

    static func toolCall(_ name: String, _ detail: String) -> String {
        "\(yellow)⚡ \(bold)\(name)\(reset)\(dim) \(detail)\(reset)"
    }

    static func success(_ text: String) -> String {
        "\(green)✓\(reset) \(text)"
    }

    static func error(_ text: String) -> String {
        "\(red)✗\(reset) \(text)"
    }

    static func thinking(_ text: String) -> String {
        "\(magenta)● \(italic)\(text)\(reset)"
    }

    static func prompt() -> String {
        "\(bold)\(blue)来财 ▸\(reset) "
    }
}

// MARK: - CLI Argument Parser

struct CLIConfig {
    var message: String?
    var pipeInput: String?
    var workspaceRoot: String?
    var interactive: Bool = false
    var showHelp: Bool = false
    var showVersion: Bool = false
    var endpoint: String?
    var model: String?
    var apiKey: String?
    var autoApprove: Bool = false
    var contextMode: String = "balanced"

    static func parse(_ args: [String]) -> CLIConfig {
        var config = CLIConfig()
        var i = 1
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--help", "-h":
                config.showHelp = true
            case "--version", "-v":
                config.showVersion = true
            case "--workspace", "-w":
                i += 1; if i < args.count { config.workspaceRoot = args[i] }
            case "--interactive", "-i":
                config.interactive = true
            case "--endpoint", "-e":
                i += 1; if i < args.count { config.endpoint = args[i] }
            case "--model", "-m":
                i += 1; if i < args.count { config.model = args[i] }
            case "--api-key", "-k":
                i += 1; if i < args.count { config.apiKey = args[i] }
            case "--yes", "-y":
                config.autoApprove = true
            case "--deep":
                config.contextMode = "deep"
            case "--economy":
                config.contextMode = "economy"
            default:
                if !arg.hasPrefix("-") && config.message == nil {
                    config.message = arg
                }
            }
            i += 1
        }

        // Check for pipe input
        if isatty(STDIN_FILENO) == 0 {
            var pipeData = Data()
            while true {
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = read(STDIN_FILENO, &buffer, buffer.count)
                if count <= 0 { break }
                pipeData.append(buffer, count: count)
            }
            if let input = String(data: pipeData, encoding: .utf8),
               !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                config.pipeInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return config
    }
}

// MARK: - Help Text

let helpText = """
\(Term.bold)\(Term.cyan)来财\(Term.reset) — 本地终端 AI Agent

\(Term.bold)用法：\(Term.reset)
  laicai <消息>                     单次执行任务
  laicai -i                         交互式 REPL (类似 Claude Code)
  <命令> | laicai <消息>             pipe 输入
  laicai --help                     显示帮助

\(Term.bold)选项：\(Term.reset)
  -w, --workspace <路径>      指定工作区（默认当前目录）
  -i, --interactive           交互模式 REPL
  -m, --model <模型名>        指定模型 (e.g. claude-3.5-sonnet)
  -e, --endpoint <URL>        指定 API endpoint
  -k, --api-key <key>         API key (或设置 LAICAI_API_KEY 环境变量)
  -y, --yes                   自动批准所有文件变更
  --deep                      深度上下文模式
  --economy                   节省 token 模式
  -h, --help                  显示帮助
  -v, --version               显示版本

\(Term.bold)示例：\(Term.reset)
  laicai "review this PR"
  laicai "fix the build error in src/main.swift"
  git diff | laicai "审查这个变更"
  laicai -i                   \(Term.dim)# 进入交互模式\(Term.reset)
  laicai -y "添加 unit tests" \(Term.dim)# 自动批准变更\(Term.reset)

\(Term.bold)环境变量：\(Term.reset)
  LAICAI_API_KEY              API key
  LAICAI_ENDPOINT             默认 endpoint
  LAICAI_MODEL                默认模型
"""

// MARK: - CLI Session State

final class CLISession {
    let workspace: String
    let connector: ConnectorProfile
    let runtime: LiveChatRuntime
    let autoApprove: Bool
    let contextMode: ContextMode
    var totalInputTokens = 0
    var totalOutputTokens = 0
    var taskCount = 0

    init(workspace: String, connector: ConnectorProfile, autoApprove: Bool, contextMode: ContextMode) {
        self.workspace = workspace
        self.connector = connector
        self.runtime = LiveChatRuntime()
        self.autoApprove = autoApprove
        self.contextMode = contextMode
    }

    func printBanner() {
        print(Term.header("来财 Terminal Agent"))
        print("\(Term.dim)  工作区: \(workspace)\(Term.reset)")
        print("\(Term.dim)  模型:   \(connector.modelName)\(Term.reset)")
        print("\(Term.dim)  端点:   \(connector.endpoint)\(Term.reset)")
        if autoApprove {
            print("\(Term.yellow)  ⚠ 自动批准模式已开启\(Term.reset)")
        }
        print(Term.footer("输入 /help 查看命令, /quit 退出"))
        print()
    }

    func printSessionStats() {
        print()
        print(Term.footer("会话统计"))
        print("\(Term.dim)  任务数: \(taskCount)  输入 tokens: \(totalInputTokens)  输出 tokens: \(totalOutputTokens)\(Term.reset)")
    }

    // MARK: - Run single task

    func runTask(message: String) async {
        taskCount += 1
        let startTime = Date()

        let loopConfig = AgentLoop.Config(
            maxIterations: 30,
            workspaceRoot: workspace,
            supportsToolCalling: true,
            contextMode: contextMode
        )
        let loop = await AgentLoop(config: loopConfig, runtime: runtime)

        let context = AutoContextEngine.buildContext(
            workspaceRoot: workspace,
            userInput: message
        )

        print(Term.header("任务 #\(taskCount)"))
        print()

        var lastStepKind: TaskStepKind?
        var pendingReviews: [(UUID, TaskStep)] = []
        let taskID = UUID()

        do {
            let completedTask = try await loop.run(
                taskID: taskID,
                message: message,
                intent: .task,
                connector: connector,
                context: context,
                onStep: { @MainActor step in
                    self.renderStep(step, lastKind: lastStepKind)
                    lastStepKind = step.kind

                    // Collect review requests for approval
                    if step.kind == .reviewRequest {
                        pendingReviews.append((step.id, step))
                    }
                },
                onStreamDelta: { @MainActor delta in
                    print(delta, terminator: "")
                    fflush(stdout)
                }
            )

            // Handle pending reviews
            for (stepID, step) in pendingReviews {
                await handleReview(step: step, stepID: stepID, taskID: taskID)
            }

            // Stats
            if let metrics = completedTask.steps.last(where: { $0.metrics != nil })?.metrics {
                totalInputTokens += metrics.inputTokens ?? 0
                totalOutputTokens += metrics.outputTokens ?? 0
            }

            let elapsed = Date().timeIntervalSince(startTime)
            let status = completedTask.status == .completed
                ? Term.success("完成")
                : Term.error("失败")
            print()
            print(Term.footer("\(status) · \(completedTask.steps.count) 步 · \(String(format: "%.1f", elapsed))秒"))

            // Summary of changed files
            let changedFiles = completedTask.steps
                .filter { ($0.kind == .reviewRequest && $0.approved == true) || ($0.kind == .toolResult && $0.toolName == "file.write" && !$0.isFailure) }
                .compactMap { $0.diffFilePath ?? $0.toolParams?["path"] }
            if !changedFiles.isEmpty {
                print("\(Term.dim)  变更文件:\(Term.reset)")
                for f in Set(changedFiles).sorted() {
                    print("    \(Term.green)M\(Term.reset) \(f)")
                }
            }
            print()

        } catch {
            print()
            print(Term.error("任务执行失败: \(error.localizedDescription)"))
            print()
        }
    }

    // MARK: - Render step to terminal

    private func renderStep(_ step: TaskStep, lastKind: TaskStepKind?) {
        switch step.kind {
        case .userInput:
            break // Already shown as prompt input

        case .aiThinking:
            let trimmed = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                print(Term.thinking(String(trimmed.prefix(120))))
            }

        case .toolCall:
            let name = step.toolName ?? "tool"
            let detail = compactToolParams(step.toolParams)
            print(Term.toolCall(name, detail))

        case .toolResult:
            if step.isFailure {
                print(Term.error("\(step.toolName ?? "tool"): \(String(step.text.prefix(200)))"))
            } else if step.toolName == "shell.exec" || step.toolName == "verify.build" {
                // Show terminal output compactly
                let lines = step.text.components(separatedBy: "\n")
                let display = lines.prefix(8).joined(separator: "\n")
                if !display.isEmpty {
                    print("\(Term.dim)\(display)\(Term.reset)")
                    if lines.count > 8 {
                        print("\(Term.dim)  ... +\(lines.count - 8) lines\(Term.reset)")
                    }
                }
            }

        case .textOutput:
            let trimmed = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && lastKind != .textOutput {
                print()
            }
            if !trimmed.isEmpty {
                print(trimmed)
            }

        case .error:
            print(Term.error(step.text))

        case .reviewRequest:
            print()
            print("\(Term.bgYellow)\(Term.bold) 📋 需要审查 \(Term.reset)")
            if let path = step.diffFilePath {
                print("  \(Term.bold)文件:\(Term.reset) \(path)")
            }
            // Show diff summary
            let lines = step.text.components(separatedBy: "\n")
            for line in lines.prefix(20) {
                if line.hasPrefix("+") {
                    print("  \(Term.green)\(line)\(Term.reset)")
                } else if line.hasPrefix("-") {
                    print("  \(Term.red)\(line)\(Term.reset)")
                } else {
                    print("  \(Term.dim)\(line)\(Term.reset)")
                }
            }
            if lines.count > 20 {
                print("  \(Term.dim)... +\(lines.count - 20) lines\(Term.reset)")
            }

        case .reviewResult:
            let approved = step.approved == true
            print(approved ? Term.success("已批准") : Term.error("已拒绝"))
        }
    }

    private func compactToolParams(_ params: [String: String]?) -> String {
        guard let p = params else { return "" }
        if let path = p["path"] { return path }
        if let cmd = p["command"] { return String(cmd.prefix(60)) }
        if let query = p["query"] { return "\"\(String(query.prefix(40)))\"" }
        if let sub = p["subcommand"] { return sub }
        return p.values.first.map { String($0.prefix(40)) } ?? ""
    }

    // MARK: - Handle review approval

    private func handleReview(step: TaskStep, stepID: UUID, taskID: UUID) async {
        if autoApprove {
            print(Term.success("自动批准"))
            return
        }

        print()
        print("\(Term.bold)批准此变更？\(Term.reset) [\(Term.green)y\(Term.reset)/\(Term.red)n\(Term.reset)/\(Term.dim)s(跳过)\(Term.reset)] ", terminator: "")
        fflush(stdout)

        guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            print(Term.error("跳过"))
            return
        }

        switch input {
        case "y", "yes", "":
            // Write the file
            if let path = step.diffFilePath, let content = step.diffNewContent {
                do {
                    try WriteFileTool().performWrite(fullPath: path, content: content, createDirectories: true)
                    print(Term.success("已写入 \(path)"))
                } catch {
                    print(Term.error("写入失败: \(error.localizedDescription)"))
                }
            }
        case "n", "no":
            print(Term.error("已拒绝"))
        default:
            print("\(Term.dim)已跳过\(Term.reset)")
        }
    }

    // MARK: - Interactive REPL

    func startREPL() async {
        printBanner()

        while true {
            print(Term.prompt(), terminator: "")
            fflush(stdout)

            guard let input = readLine() else {
                break // EOF
            }

            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            // Slash commands
            switch trimmed.lowercased() {
            case "/quit", "/exit", "/q":
                printSessionStats()
                print(Term.success("再见 👋"))
                return

            case "/help", "/h":
                printREPLHelp()
                continue

            case "/clear":
                print("\u{001B}[2J\u{001B}[H")
                printBanner()
                continue

            case "/stats":
                printSessionStats()
                continue

            case "/compact":
                print(Term.thinking("上下文已压缩"))
                continue

            default:
                break
            }

            await runTask(message: trimmed)
        }
    }

    private func printREPLHelp() {
        print()
        print("\(Term.bold)REPL 命令：\(Term.reset)")
        print("  \(Term.cyan)/help\(Term.reset)      显示此帮助")
        print("  \(Term.cyan)/quit\(Term.reset)      退出")
        print("  \(Term.cyan)/clear\(Term.reset)     清屏")
        print("  \(Term.cyan)/stats\(Term.reset)     显示 token 统计")
        print("  \(Term.cyan)/compact\(Term.reset)   压缩上下文")
        print()
        print("  直接输入自然语言即开始任务。")
        print()
    }
}

// MARK: - Connector Resolution

func resolveConnector(config: CLIConfig) -> ConnectorProfile? {
    let endpoint = config.endpoint
        ?? ProcessInfo.processInfo.environment["LAICAI_ENDPOINT"]
        ?? "https://api.openai.com/v1"
    let model = config.model
        ?? ProcessInfo.processInfo.environment["LAICAI_MODEL"]
        ?? "claude-3.5-sonnet"
    let apiKey = config.apiKey
        ?? ProcessInfo.processInfo.environment["LAICAI_API_KEY"]

    if apiKey == nil && !endpoint.contains("localhost") && !endpoint.contains("127.0.0.1") && !endpoint.contains(":11434") {
        print(Term.error("需要 API key。通过 --api-key 参数或 LAICAI_API_KEY 环境变量设置。"))
        return nil
    }

    let kind: String
    if endpoint.contains(":11434") || endpoint.contains("ollama") {
        kind = "ollama"
    } else if endpoint.contains("anthropic") {
        kind = "anthropic"
    } else {
        kind = "openai-compatible"
    }

    return ConnectorProfile(
        name: model,
        kind: kind,
        endpoint: endpoint,
        modelName: model,
        note: "CLI connector",
        health: .ready
    )
}

// MARK: - Main Entry

struct LaicaiCLI {
    static func main() async {
        let config = CLIConfig.parse(CommandLine.arguments)

        if config.showHelp {
            print(helpText)
            return
        }

        if config.showVersion {
            print("来财 CLI v1.0.0")
            return
        }

        guard let connector = resolveConnector(config: config) else {
            return
        }

        let workspace = config.workspaceRoot ?? FileManager.default.currentDirectoryPath

        let contextMode: ContextMode
        switch config.contextMode {
        case "deep": contextMode = .deep
        case "economy": contextMode = .economy
        default: contextMode = .balanced
        }

        let session = CLISession(
            workspace: workspace,
            connector: connector,
            autoApprove: config.autoApprove,
            contextMode: contextMode
        )

        // Build message from args + pipe
        var message = config.message ?? ""
        if let pipe = config.pipeInput {
            message = pipe + (message.isEmpty ? "" : "\n\(message)")
        }

        if config.interactive || (message.isEmpty && isatty(STDIN_FILENO) != 0) {
            // Interactive REPL mode
            await session.startREPL()
        } else if !message.isEmpty {
            // Single-shot mode
            await session.runTask(message: message)
            session.printSessionStats()
        } else {
            print("用法：laicai <消息>")
            print("输入 laicai --help 查看完整帮助")
        }
    }
}
