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
    public static func apiName(_ name: String) -> String {
        name.replacingOccurrences(of: ".", with: "_")
    }

    public static func canonicalName(_ name: String) -> String {
        switch name {
        case "file_read": return "file.read"
        case "file_extract": return "file.extract"
        case "file_edit": return "file.edit"
        case "file_write": return "file.write"
        case "code_search": return "code.search"
        case "workspace_index": return "workspace.index"
        case "verify_build": return "verify.build"
        case "shell_exec": return "shell.exec"
        case "web_search": return "web.search"
        case "web_fetch": return "web.fetch"
        case "wiki_build": return "wiki.build"
        case "image_generate": return "image.generate"
        case "skill_manage": return "skill.manage"
        case "lsp_query": return "lsp.query"
        case "diff_apply": return "diff.apply"
        default: return name
        }
    }
}


// Tool implementations live under Tools/.
