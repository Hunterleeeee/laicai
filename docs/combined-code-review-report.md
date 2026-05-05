# 来财 (Laicai) 项目全面代码审查报告

审查日期：2026-05-01
审查范围：`src/harness/` (Python，60+ 源文件) + `native-macos/` (Swift，~35 源文件)

---

## 项目概况

来财是一个本地优先的 AI Agent 工作空间，拥有**两套独立的代码库**：

| 维度 | Python 版 | Swift 原生版 |
|---|---|---|
| 入口 | `laicai chat` (CLI) | LaicaiNativeApp (macOS GUI) |
| 核心架构 | Agent loop + LLM adapter | AgentLoop + LiveChatRuntime |
| LLM 后端 | OpenAICompatLLM (async/httpx) | LiveChatRuntime (URLSession) |
| UI | 无 (CLI only) | SwiftUI, AppKit (NSStatusItem) |
| 数据存储 | SQLite (harness.db + sessions.db) | SQLite (统一数据库) |
| 状态管理 | 函数式 / 会话对象 | AppStore (ObservableObject) |
| 代码行数 | ~8000 | ~18000 |
| 测试覆盖 | ~30% (~3000 行未测试) | ~2000 行 (AppStoreTests) |

---

## 第一部分：跨代码库的共性问题

### 1. SQLite 操作非原子性 — 数据丢失风险

**影响：高** | 涉及：Python `adapters/storage.py` + Swift `SQLiteRepository.swift`

两套代码库都存在相同的"先删后插"非事务模式：

```python
# Python (SQLiteSessionStore)
conn.execute("DELETE FROM turns WHERE session_id = ?", (session.id,))
for t in session.turns:
    conn.execute("INSERT INTO turns ...")
```

```swift
// Swift (SQLiteRepository — saveSessions / saveTasks / saveThreads)
try db?.execute("DELETE FROM turns WHERE session_id = ?", ...)
for turn in session.turns {
    try db?.execute("INSERT INTO turns ...", ...)
}
```

如果 `DELETE` 之后、`INSERT` 完成之前进程崩溃，会话数据会完全丢失。Swift 版的 `saveThreads`、`saveTasks`、`saveConnectors` 都存在同样问题。

**建议**：两套都应当将删除+插入包装在显式事务中 (BEGIN/COMMIT 或 `INSERT OR REPLACE` + 唯一约束)。

---

### 2. 两套独立的会话/线程存储

**影响：中**

Python 版：`StateStore` (SQLite, `harness.db`) 和 `SQLiteSessionStore` (SQLite, `sessions.db`) 完全独立，数据不共享。

Swift 版：引入了统一 Thread 模型 (`ThreadRecord`)，但 `SQLiteRepository` 内部仍保留了 `sessions`、`tasks`、`threads` 三个独立的表。虽然通过 `migrateLegacyToThreads()` 做迁移，但写入路径(`saveSessions`/`saveTasks`/`saveThreads`)仍然是三套，存在数据不同步的风险。

**建议**：Swift 版应逐步废弃 `saveSessions`/`saveTasks`，统一走 `saveThreads`。Python 版应合并两个数据库。

---

### 3. 设计模式 Document-View 耦合

**影响：中**

两套代码库都存在业务逻辑和表现层混合的问题：

- **Python**: `cli/chat.py` (~530 行) 把 REPL 交互逻辑和 Agent 循环混合在一起
- **Swift**: `AppStore.swift` (2624 行) 把状态管理、代理执行、UI 更新、文件 I/O、持久化全部塞在一个文件中。`ChatDetailView.swift` (2227 行) 把工具栏、输入框、线程渲染、技能菜单、附件管理全部放在一个视图里

**建议**：Swift 版应拆分 AppStore — 将 Agent 执行逻辑分离到独立的 `AgentService`，持久化逻辑分离到 `PersistenceService`。ChatDetailView 应拆分为多个子视图组件。

---

## 第二部分：Python 代码库问题 (18 项，详见 docs/code-review-report.md)

### 严重问题

| # | 问题 | 文件 |
|---|---|---|
| 1 | **两套并行的 LLM 后端** — 新旧系统维护两套独立的 LLM 调用栈 (async vs sync) | `openai_compat.py`, `runtime.py` |
| 2 | **代码执行沙箱可绕过** — importlib、__builtins__ 未封禁 | `agent/code_runner.py` |
| 3 | **磁盘索引缓存存储完整向量** — JSON 格式存储浮点数数组体积大且慢 | `rag/vector_index.py` |
| 4 | **覆盖式测试严重不足** — ~70% 核心模块无测试 | 整个项目 |

### 中等问题

| # | 问题 | 文件 |
|---|---|---|
| 5 | VaultIndex 每次搜索全局扫描文件系统 | `rag/index.py` |
| 6 | `save_session()` 非原子性删除重插 (同 #1) | `adapters/storage.py` |
| 7 | 两套独立的会话存储 | `harness.db`, `sessions.db` |
| 8 | ContextAssembler 完整死代码 (~300 行，未被引用) | `retrieval/context.py` |
| 9 | API 密钥明文存储 | `config/loader.py` |

### 低优先级

| # | 问题 |
|---|---|
| 10 | 文件名时间戳冲突 (毫秒级) |
| 11 | `_compat_retry_bodies` 试探性重试可能吞掉真实错误 |
| 12 | `render_config_toml` 字符串拼接可能产生非法 TOML |
| 13 | `pyproject.toml` 引用不存在的 `harness.desktop` 包 |
| 14 | 内存提取器只支持中文关键词 |
| 15 | README.md 缺失 |
| 16 | 懒加载 ImportError 被静默吞掉 |
| 17 | Intent 路由未在新 Agent 中使用 |
| 18 | 技能系统与新 Agent 未集成 |

---

## 第三部分：Swift 原生版问题 (20 项)

### 严重问题

#### S1. AppStore 过度膨胀 (2624 行) — 违反单一职责原则

**影响：高** | **文件：** `AppStore.swift`

AppStore 同时承担了以下职责：
- 全局状态管理 (18+ 个 @Published 属性)
- Agent 执行循环 (sendDraft → sendTaskDraft → AgentLoop coordination)
- 流式输出缓冲 (streamBuffers, chatStreamBuffers)
- 连接器健康检查与能力学习
- 线程/会话/任务 CRUD
- 持久化 (saveSessions, saveTasks, saveThreads)
- 导出 (exportSelectedThreadMarkdown, exportSelectedThreadJSON, exportSelectedTaskEvidenceMarkdown)
- 任务记忆管理 (taskMemoryByTaskID)
- 审核工作流 (approveReview, rollbackReview)

```swift
// 一个方法里做了太多事情
public func sendDraft() {
    let message = composedDraftMessage()
    guard !message.isEmpty, !state.isGenerating else { return }
    restoreRecentTaskSelectionForTinyFollowUp(message)
    reconcileSelectedRunningTaskIfIdle()
    if answerSelectedTaskStatusQuestion(message) { return }
    var decision = IntentRouter.plan(message)
    // ...
}
```

**建议**：将 Agent 执行逻辑抽取到 `AgentService`、持久化逻辑到 `PersistenceManager`、导出逻辑到 `ExportService`。AppStore 应仅保留状态管理和 UI 协调职责。

---

#### S2. ChatDetailView 过度膨胀 (2227 行)

**影响：高** | **文件：** `ChatDetailView.swift`

这个视图包含了：工具栏 (Toolbar)、模型选择器 (modelPicker)、技能菜单 (skillPickerMenu)、文件附件 (attachmentChips)、输入框 (ComposerTextView)、状态提示 (composerStatusBar)、线程时间线 (ThreadTimelineView)、消息卡片 (TaskStepCard/ThreadEventCard) 等。所有子视图都嵌套在同一个文件中。

**建议**：将 ThreadTimelineView、模型选择器、技能菜单、附件组件等提取到独立文件。

---

#### S3. @MainActor + Task 并发隐患

**影响：高** | **文件：** `AppStore.swift`, 多处

SendDraft 流程中大量使用 `Task { @MainActor in ... }` 模式：

```swift
func sendDraft() {
    // 在 @MainActor 上执行 — 阻塞主线程
    var decision = IntentRouter.plan(message)
    // ...
    // 然后再 spawn Task
    Task {
        // 异步执行，但通过 @MainActor 状态变量通信
        // 可能被多个 Task 同时访问
        streamBuffer[taskID] = ...
    }
}
```

`streamBuffers` 和 `chatStreamBuffers` 是 [UUID: String] 字典，多个 Task 可能写入同一个 taskID。虽然通过 @MainActor 序列化了访问，但 `appendStreamDelta` 中的 buffer 操作是 `willSet`/`didSet` 驱动 UI 更新的，高频率 chunk 下可能导致性能问题。

**建议**：考虑使用 `AsyncStream` 或 `AsyncChannel` 管理流式输出，减少主线程压力。对并发写入 buffer 的场景应加明确的锁或使用 `Actor`。

---

#### S4. Shell 工具超时机制可能在阻塞中失效

**影响：中** | **文件：** `ToolEngine.swift`

```swift
// 使用 DispatchSourceTimer 在全局队列上设置超时
let timerSource = DispatchSource.makeTimerSource(queue: .global())
timerSource.schedule(deadline: .now() + .seconds(timeout))
timerSource.setEventHandler { process.terminate() }
timerSource.resume()

// 但在主线程上阻塞等待
process.waitUntilExit()  // blocking!
```

如果 `waitUntilExit()` 在 `process.terminate()` 之前已经开始阻塞，且子进程不响应 SIGTERM，则超时机制可能无效。`waitUntilExit()` 不会因为 `terminate()` 被调用就立即返回 — 它等待子进程真正退出。

**建议**：使用 `Process.run()` + 异步等待 (如 `NotificationCenter` 的 `NSWorkspace.didTerminateNotification` 或轮询 `isRunning`) 替代阻塞的 `waitUntilExit()`。或者使用 Swift 的 `AsyncProcess` (如果可用) 或 `Task` + 协程超时。

---

### 中等问题

#### S5. 网络搜索使用共享 URLSession

**影响：中** | **文件：** `ToolEngine.swift` (WebSearchTool / WebFetchTool)

```swift
// 使用 URLSession.shared
let (data, _) = try await URLSession.shared.data(from: url)
```

`URLSession.shared` 会持久化 cookies 和缓存数据。在连续搜索不同查询时，可能由于 cookie 共享而导致搜索结果受到之前搜索的影响。

**建议**：为每个请求创建 `URLSession(configuration: .ephemeral)`。

---

#### S6. SQLiteRepository 数据一致性风险

**影响：中** | **文件：** `SQLiteRepository.swift`

除了非原子性写入 (#1) 之外，还存在：
- schema 中 `threads` 表将整个 `ThreadRecord` JSON 编码为 BLOB 存储，无法进行 SQL 查询
- `loadThreads()` 返回 nil 时触发迁移，但如果数据库损坏则静默创建空数据库
- 连接器 API 密钥明文存储在 `note` 字段中
- 没有数据库版本控制或迁移机制

**建议**：添加数据库版本控制和迁移支持。考虑对敏感字段加密。对 threads 表增加可查询的列。

---

#### S7. 设计系统重复和不一致

**影响：中** | **文件：** `LaicaiTheme.swift`, `MarkdownText.swift`, 各 View

- `LaicaiTheme.swift` 定义了 `TextGrade`, `SurfaceGrade`, `AppFont`, `AppSpace`, `AppRadius`, `AppShadow`, `AppAnimation` 等完整的语义设计系统
- 但许多视图直接使用硬编码值（如 `.font(.system(size: 11, weight: .medium))`, `.padding(.leading, 72)` 等），没有使用设计 token
- 设计系统是暗色主题专属的 (所有颜色基于 `hex: "1C1B19"` 等暗色)，不支持 light mode
- `AppFont` 的名称与实际用途不一致（如 `captionMedium` vs `bodyMedium` 的区分）

**建议**：统一使用设计 token，移除所有硬编码值。添加 light mode 支持或通过 `colorScheme` 环境变量做判断。

---

#### S8. 测试辅助类的可维护性问题

**影响：中** | **文件：** `AppStoreTests.swift`

测试文件 (~2000 行) 使用了大量定制的 runtime 桩：
- `CapturingToolsRuntime` — 记录请求但不实际执行
- `StreamingRuntime` — 返回固定流式内容 "你好，世界"
- `FailingThenCapturingRuntime` — 先失败后成功
- `HealthRuntime` — 固定健康检查结果
- `ProbeHealthRuntime` — 固定探测结果
- `PausedHealthRuntime` — 可控制延迟的健康检查
- `ProviderErrorRuntime` — 总是返回 provider error
- `ToolRejectedThenPlainRuntime` — 先拒绝工具再返回纯文本
- `makeStubbedSession` — 创建 mock URLSession

**问题**：模拟行为分散在 8+ 个不同的辅助类中，没有统一的 mock 框架。测试复用了桩但没有清晰的层次结构。部分测试使用 `waitUntilIdle` 通过固定的 sleep 等待异步完成，这可能导致测试不稳定。

**建议**：引入统一的 Mock 框架 (如 `ProtocolMock`)，或使用 `swift-testing` (Swift 6) 的 parameterized tests。用 `XCTestExpectation` 代替固定等待。

---

#### S9. 构建系统分裂

**影响：中** | **文件：** `Package.swift`, `build.sh`, `typecheck.sh`

项目有三种构建方式：

1. **Package.swift** (SPM) — 定义 4 个 targets，macOS 14+
2. **build.sh** — 手动 swiftc 编译，平铺所有源文件到一个模块，目标 macOS 13.3
3. **typecheck.sh** — 手动 swiftc 分模块类型检查

`build.sh` 将跨模块的 `import LaicaiNative...` 语句用 sed 注释掉 (`// flat-build`)，然后在同一个命名空间中编译。这意味着 build.sh 构建的产物可能与 SPM 构建不一致。

此外，`Package.swift` 设定 `macOS(.v14)`，但 `build.sh` 使用 `-target arm64-apple-macos13.3`，`dist/Info.plist` 也使用 `LSMinimumSystemVersion 13.3`。版本号不一致。

**建议**：统一构建方式，废弃 `build.sh`，仅使用 SPM。如果必须支持手动构建，从 Package.swift 生成参数。

---

#### S10. In-App 通知使用字符串化 Notification Name

**影响：低** | **文件：** 多处

```swift
NotificationCenter.default.post(name: .init("LaicaiToggleCommandPalette"), object: nil)
NotificationCenter.default.post(name: .init("LaicaiToggleSearch"), object: nil)
NotificationCenter.default.publisher(for: .init("LaicaiNewThread"))
NotificationCenter.default.publisher(for: .init("LaicaiContinueLastTask"))
```

所有通知名称都是字符串字面量，分散在多个文件中。没有使用类型安全的 `Notification.Name` 扩展。

**建议**：定义 `extension Notification.Name` 静态常量，集中管理。

---

#### S11. MenuBarAgent 和 GlobalShortcutManager 初始化时机

**影响：低** | **文件：** `LaicaiNativeApp.swift`

```swift
init() {
    let store = AppStore.live()
    _store = StateObject(wrappedValue: store)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        store.checkAllConnectorsHealth()
    }
    MenuBarAgent.shared.install()
    GlobalShortcutManager.shared.install()
    NotificationManager.shared.requestPermission()
}
```

全局单例在 App init 中安装，此时 AppStore 可能尚未准备好。0.8 秒延迟是硬编码的 Magic Number，在不同性能的机器上可能不够或不必要。

**建议**：使用 `.onAppear` 或 `.task` 修饰符在视图加载后执行初始化，避免在 `init` 中做副作用操作。

---

### 低优先级问题

#### S12. 全局单例模式滥用

**影响：低**

- `ToastCenter.shared` — 全局 Toast 单例
- `MenuBarAgent.shared` — 菜单栏单例
- `GlobalShortcutManager.shared` — 快捷键单例
- `SkillRegistry.shared` — 技能注册表单例
- `AuditLog.shared` — 审计日志单例

所有依赖都通过 `.shared` 直接引用，难以测试替代或隔离。

**建议**：通过 SwiftUI 的 environment 或依赖注入传递这些依赖。

---

#### S13. 线程时间线步骤折叠硬编码

**影响：低** | **文件：** `ChatDetailView.swift`

```swift
private let compactStepLimit = 72
```

当任务步骤超过 72 条时折叠早期步骤。这个阈值是硬编码的，没有与 ContextMode 联动（economy 模式应该更早折叠）。

**建议**：与 ContextMode 联动，或根据当前 token 预算动态调整折叠阈值。

---

#### S14. SampleData.swift 硬编码路径

**影响：低** | **文件：** `SampleData.swift`

```swift
// 硬编码的工作区路径
workspacePath: "/Users/lifenghe/Documents/troe_projects/harness"
```

预览数据中包含机器特定的绝对路径，可能导致预览渲染异常或安全敏感信息暴露。

**建议**：预览数据使用 `/tmp` 或空字符串路径。

---

#### S15. Thread 模型中的逻辑混淆

**影响：低** | **文件：** `Models.swift`, `AppStore.swift`

`Thread.source` 是计算属性而非存储属性：

```swift
public var source: ThreadSource {
    context.workspaceRoot.isEmpty && workflowName == nil && steps.allSatisfy {
        $0.kind == .userInput || $0.kind == .textOutput || $0.kind == .aiThinking || $0.kind == .error
    } ? .session : .task
}
```

这意味着如果某个 session-only 线程偶然有一个 toolCall 步骤，source 会从 `.session` 变为 `.task`，可能导致 UI 中的分类错误。

**建议**：将 `source` 改为存储属性，在创建 Thread 时明确指定。

---

#### S16. 一些 View 使用 @ViewBuilder + 条件分支导致 id 重置

**影响：低**

```swift
// ThreadTimelineView 中的条件分支
if let task = thread.task {
    TaskSummaryCard(task: task)
    // ...
} else {
    ForEach(thread.events) { event in
        ThreadEventCard(event: event)
    }
}
```

当 thread.source 在 session 和 task 之间切换时，会完全替换视图树，导致滚动位置丢失。

**建议**：使用 ZStack 或 `id` 修饰符保持滚动状态。

---

#### S17. WorkflowLibrary 使用静态可变状态

**影响：低** | **文件：** `WorkflowEngine.swift`

```swift
public static var lastLoadErrors: [String] = []
```

`WorkflowLibrary.lastLoadErrors` 是静态可变属性，在多线程访问时可能产生竞争。

**建议**：改为实例属性，通过依赖注入传递。

---

#### S18. 审计日志内存上限硬编码

**影响：低** | **文件：** `SecurityEngine.swift`

```swift
private let maxEntries = 500
```

审计日志最大记录数是硬编码的 500 条。超过此限制的条目会被静默丢弃。没有持久化，应用重启后日志丢失。

**建议**：将审计日志持久化到 SQLite，提供可配置的上限。

---

#### S19. 审核工作流的 diff 未做严格校验

**影响：低** | **文件：** `AppStore.swift`

```swift
case .approveReview:
    // diff old/new content 直接写入文件，没有校验 diff 是否可安全应用
    let newContent = diffNewContent ?? content
    try newContent.write(to: fileURL, atomically: true, encoding: .utf8)
```

审核通过时直接将新内容写入文件，如果 diff 不可逆（如文件内容已在审核期间被外部修改），可能导致数据不一致。

**建议**：写入前校验文件的 mtime 或 content hash 是否与审核时一致。

---

#### S20. dist/Info.plist 中版本号为硬编码

**影响：低** | **文件：** `dist/Laicai.app/Contents/Info.plist`

```xml
<key>CFBundleShortVersionString</key>
<string>0.1</string>
<key>CFBundleVersion</key>
<string>1</string>
```

版本号硬编码在 dist 目录中。如果使用 SPM 构建的应用 bundle，应在 Info.plist 中引用构建时的版本号。

**建议**：使用 `agvtool` 或构建脚本从 git tag 自动生成版本号。

---

## 第四部分：两代码库对比分析

### 架构差异

| 维度 | Python | Swift |
|---|---|---|
| 设计哲学 | 先有 legacy 后有 refactor | 从零开始设计，有统一 Thread 模型 |
| 代码品质 | 遗留代码多、死代码多 | 较新，但有过度膨胀趋势 |
| 测试覆盖 | ~30% | ~12%（仅 AppStore 有测试） |
| LLM 集成 | 2 套后端，async+sync | 1 套后端 (LiveChatRuntime)，纯 async |
| 安全模型 | 黑名单式 sandbox (可绕过) | 白名单式 policy + workspace boundary |
| 文件大小 | ~8000 行/60 文件 | ~18000 行/35 文件 |
| UI | 无UI (CLI only) | SwiftUI + AppKit (macOS 原生) |

### 安全问题

| 维度 | Python | Swift |
|---|---|---|
| 代码注入 | ⚠️ 黑名单可绕过 (importlib) | ✅ 无代码执行能力 |
| API 密钥 | ⚠️ 明文 TOML 配置 | ⚠️ 明文 SQLite note 字段 |
| Shell 执行 | ⚠️ 无隔离 | ⚠️ 白名单但有阻塞超时问题 |
| 项目边界 | ❌ 无保护 | ✅ WorkspaceSandbox |

### 测试对比

| 维度 | Python | Swift |
|---|---|---|
| 测试框架 | pytest | XCTest |
| 测试行数 | ~1200 | ~2000 |
| 未测试核心模块 | agent/loop.py (330行), openai_compat.py (310行) | AgentLoop.swift (2224行), ToolEngine.swift (1422行) |
| 主要测试对象 | 语义路由、Planner、Chunker | AppStore (状态管理、路由、连接器) |
| Mock 策略 | pytest fixtures + MagicMock | 定制协议实现类 |

---

## 第五部分：改进建议优先级

### P0 — 安全与数据完整性

| 优先级 | 问题 | 涉及 | 影响 |
|---|---|---|---|
| 🔴 P0 | SQLite 非原子性写入 | Python + Swift | 数据丢失风险 |
| 🔴 P0 | Python 代码沙箱可绕过 | Python | 代码注入 |
| 🔴 P0 | AppStore 拆分重构 | Swift | 可维护性 |

### P1 — 架构统一

| 优先级 | 问题 | 涉及 | 影响 |
|---|---|---|---|
| 🟠 P1 | 统一两套 Python LLM 后端 | Python | 维护成本 |
| 🟠 P1 | Python 测试覆盖核心模块 | Python | 质量保障 |
| 🟠 P1 | Swift AgentLoop 测试 | Swift | 质量保障 |
| 🟠 P1 | 构建系统统一 (废弃 build.sh) | Swift | 构建一致性 |

### P2 — 设计改进

| 优先级 | 问题 | 涉及 | 影响 |
|---|---|---|---|
| 🟡 P2 | 清理 Python 死代码 (ContextAssembler) | Python | 代码整洁 |
| 🟡 P2 | ChatDetailView 拆分 | Swift | 可维护性 |
| 🟡 P2 | API 密钥加密存储 | Python + Swift | 安全 |
| 🟡 P2 | 添加 README.md | Python | 缺失 |
| 🟡 P2 | DuckDuckGo HTML 抓取加固 | Swift | 可靠性 |

### P3 — 长期优化

| 优先级 | 问题 | 涉及 | 影响 |
|---|---|---|---|
| 🟢 P3 | Swift 设计系统 light mode 支持 | Swift | UI 兼容性 |
| 🟢 P3 | 全局单例 → DI 重构 | Swift | 可测试性 |
| 🟢 P3 | VaultIndex 性能优化 | Python | 性能 |
| 🟢 P3 | 审计日志持久化 | Swift | 可用性 |
| 🟢 P3 | 通知名称类型安全 | Swift | 代码质量 |
| 🟢 P3 | Intent 路由与新 Agent 打通 | Python | 架构完整性 |

---

## 总结

来财项目拥有**超前的架构设计**（统一 Thread 模型、Phase-aware Agent 循环、自动工具兼容性检测、连接器能力学习），但也存在**初创项目典型的成长痛**：

1. **Python 版**面临的主要是"两套后端、测试不足、安全沙箱可绕过"的遗留问题
2. **Swift 版**面临的主要是"过度膨胀的 AppStore 和 UI 视图、并发模型安全、构建系统分裂"的成长问题
3. **两套代码库共有的**问题是 SQLite 非原子性写入和 API 密钥明文存储

核心建议：**Swift 版应优先拆分 AppStore 和 ChatDetailView**（这两文件合计 ~4850 行，占总 Swift 代码的 27%），然后补 AgentLoop 测试。**Python 版应优先统一 LLM 后端**，然后补核心模块测试。

*本报告基于 2026-05-01 的完整源码审查生成。Python 覆盖 60+ 源文件，Swift 覆盖 35 个源文件中的 30+ 个。部分 UI 视图细节和极少数边缘路径未完全审查。*
