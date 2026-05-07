# macOS 原生版架构现状

本项目当前主线是全原生 Swift macOS 应用，配套一个可脚本化 CLI。旧的 Python/Electron 方案只作为历史参考，不再描述为运行时依赖。

## 当前分层

### App

- `LaicaiNativeApp`：SwiftUI 应用入口、菜单命令、Settings 场景。
- `LaicaiNativeUI`：三栏工作台、聊天详情、工作台面板、设置页、技能中心等 SwiftUI/AppKit 视图。

### Domain

- `LaicaiNativeDomain`：线程、任务步骤、连接器、工具调用、工作流、设置等 Codable/Sendable 数据模型。
- `Thread` 是当前权威会话模型；`ChatSession` 和 `AgentTask` 保留为兼容与迁移类型。

### Foundation

- `AppStore`：当前应用状态和命令编排中心。
- `AgentLoop`：模型请求、工具调用、恢复、验证和任务循环。
- `ToolEngine`：文件、搜索、shell、git、wiki、图片等工具实现。
- `LiveChatRuntime`：OpenAI-compatible / Ollama 等连接器运行时。
- `SQLiteRepository`：线程、连接器、旧 session/task 迁移和持久记忆。
- `SkillEngine` / `WorkflowEngine` / `GoalEngine` / `SchedulerEngine`：技能、工作流、目标和定时任务。

### CLI

- `LaicaiNativeCLI`：终端 Agent 入口，复用 `LaicaiNativeFoundation` 和 `LaicaiNativeDomain`。
- SwiftPM product 为 `laicai`，构建脚本也会把 CLI 复制到 `native-macos/dist/laicai`。

## 构建与发布

- `native-macos/Package.swift` 是标准 SwiftPM 构建入口。
- `native-macos/build.sh` 负责生成本地开发 `.app` bundle、CLI 和安装脚本。
- 默认最低系统版本与 Package 保持 macOS 14，默认架构为 arm64 + x86_64。

## 数据与迁移

- 应用数据默认在 `~/Library/Application Support/Laicai`。
- `threads` 表存储统一 `Thread` JSON。
- 旧 `sessions` / `tasks` 表在首次加载统一线程为空时迁移为 `Thread`。
- 新增字段必须在 Codable 解码中提供默认值，避免旧线程记录静默丢失。

## 当前技术债

- `AppStore`、`AgentLoop`、`ToolEngine`、`WorkbenchPanels` 仍然过大。CI 现在会对超过 2500 行的 Swift 文件给出 warning，超过 5500 行失败，避免继续膨胀。
- 拆分优先级：
  - `AgentLoop`：先拆 `PromptComposer`、恢复/压缩、模板预执行、工具重试策略。
  - `AppStore`：先拆 persistence sync、自我改进、connector health、thread/session mutation。
  - `ToolEngine`：按工具族拆到 `Tools/FileTools.swift`、`Tools/ShellTools.swift`、`Tools/WebTools.swift`、`Tools/ImageTools.swift`。
  - `WorkbenchPanels`：按面板拆出 settings、memory、workflow、skill、goal 子视图。
- 并发边界已收敛到 `Locked`、actor 或 `@MainActor`。新增 `@unchecked Sendable` 必须附带原因，并优先用 `Locked` 包住可变状态。
- URLSession 普通 REST/探测调用应走 `NetworkDefaults.ephemeralSession`，WebSocket 调用走 `NetworkDefaults.webSocketSession`。
- 测试覆盖仍需继续补齐，尤其是 `ToolEngine`、`AgentLoop`、`SkillEngine` 的失败恢复和迁移路径。
