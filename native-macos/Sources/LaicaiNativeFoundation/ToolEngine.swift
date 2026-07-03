import Foundation
import LaicaiNativeDomain

// MARK: - Tool Registry

@MainActor
public final class ToolRegistry {
    public static let shared = ToolRegistry()
    private var tools: [String: any LaicaiTool] = [:]

    private init() {
        register(ReadFileTool())
        register(ExtractFileTool())
        register(DocumentTransformTool())
        register(FileEditTool())
        register(WriteFileTool())
        register(ShellTool())
        register(SearchTool())
        register(WorkspaceIndexTool())
        register(VerifyBuildTool())
        register(WebSearchTool())
        register(WebFetchTool())
        register(WikiBuildTool())
        register(GitTool())
        register(ComfyUITool())
        register(LSPTool())         // G3: LSP go-to-definition / find-references
        register(DiffApplyTool())   // G11: Unified diff apply
        register(SkillManageTool()) // Agent self-creates/updates/deletes skills
        register(BrowserTool())     // Browser control: navigate, extract, screenshot, JS
        register(MemoryTool())      // Cross-session memory: store, recall, search
        register(PMAgentTool())     // Product Manager agent: PRD, user stories, competitive analysis
        #if !LAICAI_CLI
        register(ComputerTool())    // macOS automation: open apps, keystrokes, clipboard, screenshots
        register(RealBrowserTool()) // Real browser control: Safari/Chrome via AppleScript
        #endif
    }

    public func register(_ tool: any LaicaiTool) {
        tools[tool.name] = tool
    }

    public func tool(named name: String) -> (any LaicaiTool)? {
        tools[ToolNameCodec.canonicalName(name)]
    }

    public var allTools: [any LaicaiTool] {
        Array(tools.values)
    }

    /// Get tool definitions for OpenAI function calling
    public var toolDefinitions: [ToolDefinition] {
        allTools.map { tool in
            var function = tool.functionDefinition
            function.name = ToolNameCodec.apiName(tool.name)
            return ToolDefinition(function: function)
        }
    }
}

public enum ToolNameCodec {
    private static let canonicalNames: [String: String] = [
        "file_read": "file.read",
        "file_extract": "file.extract",
        "document_transform": "document.transform",
        "file_edit": "file.edit",
        "file_write": "file.write",
        "code_search": "code.search",
        "workspace_index": "workspace.index",
        "verify_build": "verify.build",
        "shell_exec": "shell.exec",
        "web_search": "web.search",
        "web_fetch": "web.fetch",
        "wiki_build": "wiki.build",
        "image_generate": "image.generate",
        "skill_manage": "skill.manage",
        "lsp_query": "lsp.query",
        "diff_apply": "diff.apply",
        "pm_agent": "pm.agent",
        "browser_real": "browser.real",
        "computer_tool": "computer"
    ]

    public static func apiName(_ name: String) -> String {
        name.replacingOccurrences(of: ".", with: "_")
    }

    public static func canonicalName(_ name: String) -> String {
        canonicalNames[name] ?? name
    }
}

// Tool implementations live under Tools/.
