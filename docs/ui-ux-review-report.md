# 来财原生版 UI/UX 审查报告

审查日期：2026-05-01
审查范围：所有 SwiftUI 视图 (~8,000 行 UI 代码)

---

## 目录

1. [Bug：工具结果默认折叠，用户看不到执行反馈](#bug1)
2. [Bug：通知重复不触发，toast 可能丢失](#bug2)
3. [Bug：打开 App 时闪一下"未配置模型"再变成就绪](#bug3)
4. [Bug：滚动到底部使用硬编码延迟——内容多时失效](#bug4)
5. [Bug：Diff 预览算法极端情况下输出混乱](#bug5)
6. [Bug：Composer 焦点状态延迟一帧——闪烁](#bug6)
7. [UX：侧栏线程预览对任务线程几乎无用](#ux1)
8. [UX：阶段进度条表达歧义——已完成步骤也算进入数](#ux2)
9. [UX：工具栏的"回滚检查点"和"重试"按钮位置不合理](#ux3)
10. [UX：命令面板不支持键盘上下选择](#ux4)
11. [UX：快捷键冲突 (⌘N, ⌘F) 与系统快捷键重叠](#ux5)
12. [UX：工具调用理由都是静态文案——无信息量](#ux6)
13. [UX：输入框没有显示当前选中任务的上下文](#ux7)
14. [UX：第一次启动——健康检查完成前 UI 处于不确定态](#ux8)
15. [UX：错误不可恢复时没有任何引导操作](#ux9)
16. [UX：侧栏搜索不搜索对话内容](#ux10)
17. [UX：审查阶段的 diff 计算重复——UI 和 copy 各一份](#ux11)
18. [UX：流式输出中长回复 UI 卡顿](#ux12)
19. [UX：任务卡片中的"记忆药丸"过于技术化](#ux13)
20. [UX：审查卡片的 riskLabel 硬编码关键词——误报/漏报](#ux14)
21. [UX：右侧面板的"资源"标签永远为空——占位无用](#ux15)
22. [UX：设计系统不一致——硬编码值随处可见](#ux16)
23. [UX：无"发送撤销"——发出后无法取消](#ux17)

---

<a name="bug1"></a>
## 🔴 Bug 1：工具结果默认折叠，用户看不到执行反馈

**位置：** `Models.swift:197` — `TaskStep.init` 中 `isCollapsed` 默认值
**严重性：** **高**

### 问题

```swift
// Models.swift — TaskStep 初始化参数默认值
public init(
    ...
    isCollapsible: Bool = false,
    isCollapsed: Bool = true,  // ← 默认 true！
    ...
)
```

所有 `TaskStep` 的 `isCollapsed` 默认为 `true`，且 `isCollapsible` 默认为 `false`。而 `ToolResultCard` 的渲染逻辑是：

```swift
// ChatDetailView.swift:1193
case .toolResult:
    if step.isCollapsed && !step.isFailure {
        EmptyView()  // ← 默认折叠，无展开按钮！
    } else {
        ToolResultCard(step: step)
    }
```

**后果：** 每个成功的工具结果都默认不显示。用户看到线程里只有"调用工具 → 读取文件"之类的行，但看不到文件内容。这不是折叠（有展开按钮），而是直接隐藏了。

### 修复

两个方向选一个：
1. 将 `isCollapsed` 默认值改为 `false`，仅在步骤超过阈值时由代码折叠
2. 或者，移除 `ToolResultCard` 的 `EmptyView` 分支，始终展示结果（工具结果不应该折叠）

**推荐方案 2**：工具结果是用户理解 Agent 行为的关键信息，不应该默认隐藏。

---

<a name="bug2"></a>
## 🔴 Bug 2：通知重复不触发 Toast

**位置：** `RootView.swift:55`
**严重性：** **中**

### 问题

```swift
.onChange(of: store.state.notice) { notice in
    guard let notice else { return }
    // show toast
}
```

`notice` 是 `AppNotice?` 可选类型。当两次通知内容完全相同时（例如连续两次"已保存"），SwiftUI 的 `onChange` 不会触发，因为 old value == new value。第二个 toast 被静默丢弃。

### 修复

```swift
// 方案：添加计数器或 UUID，确保每次变化都不同
store.state.notice = AppNotice(message: "已保存", id: UUID())

// RootView
.onChange(of: store.state.notice?.id) { _ in
    guard let notice = store.state.notice else { return }
    // show toast
}
```

---

<a name="bug3"></a>
## 🔴 Bug 3：打开 App 时闪一下"未配置模型"再变成就绪

**位置：** `LaicaiNativeApp.swift:13`, `AppStore.swift:bootstrap`
**严重性：** **中**

### 问题

```swift
// LaicaiNativeApp.swift:init
DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
    store.checkAllConnectorsHealth()
}
```

用户看到的流程：
1. 打开 App → UI 立即渲染 → `activeConnector` 存在但 `health` 是 `.attention`
2. 侧栏 footer 显示黄色圆点"模型需确认"
3. ChatDetailView 的 model picker 可能显示正常
4. 0.8 秒后健康检查运行 → 变为绿色"就绪"
5. 如果用户在这 0.8 秒内尝试输入，输入框是半透明的（`activeConnector == nil` 判断错误？实际上 connector 存在但 health 是 attention）

检查 `canSend` 逻辑：
```swift
private var canSend: Bool {
    let hasText = !store.state.draftMessage.trimmingCharacters(...).isEmpty
    return (hasText || !store.state.draftAttachments.isEmpty) && store.state.activeConnector != nil
}
```
只检查 `activeConnector` 非 nil，不管 health 状态。所以用户可以在模型 attention 状态下发送消息，但消息会失败。

### 修复

1. 在 App bootstrap 中先做健康检查，再显示 UI
2. 或者在 sidebar footer 中直接显示 loading spinner 而非"模型需确认"
3. 在 `canSend` 或 `sendDraft` 入口检查 `activeConnector?.health == .ready`

---

<a name="bug4"></a>
## 🟡 Bug 4：滚动到底部使用硬编码延迟——内容多时失效

**位置：** `ChatDetailView.swift:758-774`
**严重性：** **中**

### 问题

```swift
private func settleAtBottom(_ proxy: ScrollViewProxy) {
    scrollToBottom(proxy)
    for delay in [0.05, 0.15, 0.35] {  // ← 硬编码延迟
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            scrollToBottom(proxy)
        }
    }
}
```

当响应很长或 LLM 推理较慢时，0.35 秒可能不够视图完成布局。每次新消息到来时反复调用 `settleAtBottom`，如果用户手动向上滚动查看历史，会被强制拉回底部。

`scheduleScrollToBottom` 更精确但同样使用硬编码的 0.03 秒：
```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
    guard token == scrollToken else { return }
    scrollToBottom(proxy)
}
```

### 修复

```swift
// 使用 scrollTo 的 anchor: .bottom 和 withAnimation 的 completion
// 或用 GeometryReader 动态检测内容高度变化
// 更关键：只在流式输出阶段自动滚动，不要在用户手动滚动后抢占
@State private var userScrolledAway = false

// 检测用户滚动
ScrollView {
    // ...
}
.onReceive(NotificationCenter.default.publisher(for: NSScrollView.willStartLiveScrollNotification)) { _ in
    userScrolledAway = true
}
// 新消息来时检查距离底部距离，远就不自动滚
```

---

<a name="bug5"></a>
## 🟡 Bug 5：Diff 预览算法极端情况下输出混乱

**位置：** `ChatDetailView.swift:1819-1881` — `simpleDiff`
**严重性：** **中**

### 问题

`simpleDiff` 是一个自定义的行级 diff 引擎。存在多个问题：

1. **while 循环中的 break 逻辑可能漏掉部分行**（第 1846/1853/1867 行的 break）
2. **嵌套循环复杂**：idx 在多个循环中被修改，不可预测
3. **大段行变化时输出混乱**：连续增减行时可能输出错位的 + 和 -
4. **fallback 是全量无分组**：当算法"什么都没产生"时，简单输出所有 `-` 行再接所有 `+` 行，完全无法阅读

### 修复

```swift
// 方案 A：使用成熟的 diff 库
// import SwiftDiff 或 DifferenceKit

// 方案 B：简化算法
private static func simpleDiff(old: String, new: String) -> [DiffLine] {
    let oldLines = old.components(separatedBy: "\n")
    let newLines = new.components(separatedBy: "\n")
    // 使用 Myers diff 算法或更简单的 LCS
    // ...
}
```

---

<a name="bug6"></a>
## 🟡 Bug 6：Composer 焦点状态延迟一帧——闪烁

**位置：** `ComposerTextView.swift:78-81`
**严重性：** **低**

### 问题

```swift
func setFocused(_ value: Bool) {
    DispatchQueue.main.async {
        self.focused.wrappedValue = value  // ← 延迟一帧
    }
}
```

`setFocused` 已经是从 AppKit delegate 回调调用的，理论上已在主线程。额外包一层 `DispatchQueue.main.async` 导致焦点更新延迟到下一个 runloop iteration。UI 中的 `composerFocused` 绑定 被用于控制输入框边框颜色，延迟一帧会导致边框颜色闪烁。

### 修复

```swift
func setFocused(_ value: Bool) {
    self.focused.wrappedValue = value  // 直接设置，无需 dispatch
}
```

---

<a name="ux1"></a>
## 🟠 UX 1：侧栏线程预览对任务线程几乎无用

**位置：** `SidebarView.swift:600-614` — `sanitizedPreview`
**严重性：** **中**

### 问题

```swift
private func sanitizedPreview(_ text: String) -> String {
    if item.status == .cancelled { return "已暂停..." }
    if item.status == .failed { return "执行失败..." }
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.hasPrefix("请求失败") || t.contains("Request failed") { return "请求失败..." }
    if t.count > 60 { return String(t.prefix(57)) + "…" }
    return t.isEmpty ? "暂无内容" : t
}
```

任务线程的 `preview` 来自 `AgentTask.preview`：
```swift
public var preview: String {
    if let lastStep = steps.last {
        let truncated = lastStep.text.prefix(60).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(truncated)
    }
    return "空任务"
}
```

这导致大多数任务线程在侧栏中显示为工具调用文本或技术输出，例如：
- `调用 项目索引...`（toolCall 的描述文字）
- `正在搜索项目内容...`（toolCall 的描述文字）
- `搜索到了 10 个 SwiftUI...`（toolResult 的摘要）

对用户来说，这些预览完全不可读，无法快速区分两个任务。

### 修复

```swift
public var preview: String {
    if let lastStep = steps.last(where: { $0.kind == .userInput || $0.kind == .textOutput }) {
        // 优先显示用户输入或 AI 回复
    }
    // 或从 steps 中提取最有意义的摘要
}
```

---

<a name="ux2"></a>
## 🟠 UX 2：阶段进度条表达歧义——已完成步骤也算入

**位置：** `ChatDetailView.swift:1052-1107` — `phaseProgressBar`
**严重性：** **中**

### 问题

```swift
// phaseProgressBar 显示每个阶段的步骤数量
// 例如：探索(3) 执行(1) 验证(0) 总结(0)
```

如果任务完成了探索阶段的 3 步、执行阶段的 1 步，进度条显示的是"已完成的步骤数量"，而不是"剩余步骤数量"。用户看到 `验证(0)` 会以为验证还没执行，但实际上可能验证阶段根本没有需要验证的事项。

更严重的是，当探索阶段有 15 步、执行阶段有 2 步时，显示 `探索(15) 执行(2)` 看起来像还有 17 步要执行，但实际上这些步骤已全部完成。

### 修复

```swift
// 方案：区分"已完成"和"进行中"
// 已完成步骤用浅色/填充，当前阶段高亮
// 不显示计数，或只显示当前阶段的活跃步骤数
```

---

<a name="ux3"></a>
## 🟠 UX 3：工具栏的"回滚检查点"和"重试"按钮位置不合理

**位置：** `ChatDetailView.swift:111-131`
**严重性：** **低**

### 问题

```swift
Menu {
    Button { store.undoLastCheckpoint() } label: {
        Label("回滚检查点", systemImage: "arrow.uturn.backward")
    }
    Button { store.retryLastMessage() } label: {
        Label("重试", systemImage: "arrow.clockwise")
    }
    Divider()
    Button(role: .destructive) {
        store.clearSelectedThread()
    } label: {
        Label("清空", systemImage: "eraser")
    }
} label: { ... }
```

"回滚检查点"和"重试"放在同一个菜单中，使用频率完全不同：
- **重试**：高频操作（生成结果不满意时立即重试）
- **回滚检查点**：极低频操作（只有创建了检查点后才有意义）
- **清空**：危险操作（取消确认）和温和操作放在一起

用户需要点击两次（打开菜单→点击）才能重试，而重试是最常用的操作之一。

### 修复

```swift
// 将"重试"直接暴露为按钮，菜单只放低频/危险操作
HStack {
    Button { store.retryLastMessage() } label: {
        Image(systemName: "arrow.clockwise")
    }
    .help("重试")
    
    Menu {
        Button { store.undoLastCheckpoint() } label: { ... }
        Divider()
        Button(role: .destructive) { store.clearSelectedThread() } label: { ... }
    } label: { Image(systemName: "ellipsis") }
}
```

---

<a name="ux4"></a>
## 🟠 UX 4：命令面板不支持键盘上下选择

**位置：** `CommandPaletteView.swift`
**严重性：** **中**

### 问题

命令面板有一个搜索输入框和结果列表，但是**不支持键盘导航**：
- 输入文字后过滤结果
- 结果显示为按钮列表
- 但用户不能按 `↓`/`↑` 选择、按 `Enter` 执行

用户必须用鼠标点击结果。这与 macOS 上标准的命令面板 UX（如 Raycast、Alfred、Spotlight）完全不同。

### 修复

```swift
@State private var selectedIndex = 0

var body: some View {
    // ...
    .onKeyPress(.downArrow) { 
        selectedIndex = min(selectedIndex + 1, filteredActions.count - 1)
        return .handled
    }
    .onKeyPress(.upArrow) { 
        selectedIndex = max(selectedIndex - 1, 0)
        return .handled
    }
    .onKeyPress(.return) { 
        run(filteredActions[selectedIndex])
        return .handled
    }
}
```

---

<a name="ux5"></a>
## 🟠 UX 5：快捷键冲突与系统快捷键重叠

**位置：** `LaicaiNativeApp.swift:31-63`
**严重性：** **低**

### 问题

```swift
// LaicaiNativeApp.swift
Button("新线程") { store.newSession() }
    .keyboardShortcut("n", modifiers: [.command])  // ⌘N = 新线程 vs 新建窗口

Button("搜索") { ... }
    .keyboardShortcut("f", modifiers: [.command])  // ⌘F = 搜索 vs 系统查找
```

`⌘N` 是 macOS 标准的"新建窗口"快捷键，`⌘F` 是"查找"。如果用户在任何文本输入框中按 `⌘F`，预期是打开查找栏，但实际上会触发来财的搜索面板。

### 修复

```swift
.keyboardShortcut("n", modifiers: [.command, .shift])  // ⌘⇧N 新建线程
.keyboardShortcut("f", modifiers: [.command, .option])  // ⌘⌥F 搜索
```

---

<a name="ux6"></a>
## 🟠 UX 6：工具调用理由都是静态文案——无信息量

**位置：** `ChatDetailView.swift:1385-1408` — `toolReason`
**严重性：** **低**

### 问题

```swift
private var toolReason: String {
    let phase = AgentLoop.inferPhase(from: ...)
    switch step.toolName {
    case "code.search":
        return phase == .explore ? "定位相关代码或文件，再精确读取。" : "搜索验证目标或定位修复点。"
    case "file.read":
        return phase == .explore ? "读取真实文件内容，避免凭空推断。" : "确认当前内容再修改。"
    // ...
    }
}
```

每次调用 `file.read` 都显示"读取真实文件内容，避免凭空推断。"——用户看一次就知道，看十次就是噪音。这些文案占用了宝贵的垂直空间，但没有提供实际有用的信息（比如"正在读取 Sources/App/AppStore.swift"）。

### 修复

```swift
// 显示实际参数内容而不是固定文案
if let params = step.toolParams {
    // file.read → 显示路径
    // code.search → 显示搜索词
    // shell.exec → 显示命令前 30 字符
}
```

---

<a name="ux7"></a>
## 🟠 UX 7：输入框没有显示当前选中任务的上下文

**位置：** `ChatDetailView.swift:550-554`
**严重性：** **低**

### 问题

```swift
private var composerPlaceholder: String {
    if store.state.activeConnector == nil { return "先连接模型…" }
    if store.state.selectedTask != nil { return "继续任务…" }
    return "说点什么…"
}
```

当选中某个任务时，placeholder 从"说点什么…"变成"继续任务…"。但用户看不到当前选中的任务是什么——只能看到工具栏里被截断的任务标题（`frame(maxWidth: 360)`）。如果侧栏也折叠了，用户完全不知道上下文是什么。

### 修复

```swift
// 在输入框上方添加一个小的上下文 chip
if let task = store.state.selectedTask {
    HStack(spacing: AppSpace.xs) {
        Image(systemName: task.status.icon)
        Text(task.title)
            .lineLimit(1)
        Button { store.selectTask(id: nil) } label: {
            Image(systemName: "xmark")
        }
    }
    .font(AppFont.tiny)
    .foregroundStyle(TextGrade.muted)
}
```

---

<a name="ux8"></a>
## 🟠 UX 8：第一次启动时 UI 处于不确定态

**位置：** `AppStore.swift:bootstrap`, `LaicaiNativeApp.swift:init`
**严重性：** **低**

### 问题

启动流程：
1. `init()` 创建 AppStore
2. AppStore.bootstrap() 加载 UserDefaults 和 SQLite 数据
3. `DispatchQueue.main.asyncAfter(0.8s)` 才触发健康检查

这 0.8 秒内：
- 侧栏 footer 显示黄色"模型需确认"
- 输入框是半透明的（如果 connector 不存在）
- 用户无法发送消息

如果用户网络慢，健康检查需要更长时间（Ollama API 或 OpenAI API），0.8 秒不够。

### 修复

```swift
// bootstrap 中立即触发健康检查，同时显示 loading 状态
func bootstrap() {
    loadSettings()
    loadThreads()
    loadConnectors()
    // 异步健康检查
    Task {
        await checkAllConnectorsHealth()
    }
}
// 在 UI 中直接显示 loading spinner
```

---

<a name="ux9"></a>
## 🟠 UX 9：错误不可恢复时没有任何引导操作

**位置：** `ChatDetailView.swift:1547-1651` — `ErrorCard`
**严重性：** **低**

### 问题

```swift
// ErrorCard 中
if step.recoverable {
    // 显示"继续任务"和"解释原因"按钮
} // else: 什么都不显示
```

当 `step.recoverable` 为 false 时（如认证失败、安全拦截），用户看到红色的错误卡片但没有可点击的操作。用户不知道该做什么——是重试？去设置检查？还是放弃？

### 修复

```swift
// 即使是不可恢复的错误，也提供引导
if !step.recoverable {
    // 根据错误类型提供操作建议
    if error.contains("鉴权") || error.contains("401") {
        Button("检查模型配置") { showingSettings = true }
    } else if error.contains("安全") || error.contains("策略拦截") {
        Button("查看安全日志") { selectWorkbenchTab(.logs) }
    } else {
        Button("重试") { store.retryLastMessage() }
    }
}
```

---

<a name="ux10"></a>
## 🟠 UX 10：侧栏搜索不搜索对话内容

**位置：** `SidebarView.swift:93-115`
**严重性：** **低**

### 问题

```swift
private var matchingThreads: [ThreadRecord] {
    store.state.threadSummaries.filter { thread in
        thread.title.localizedCaseInsensitiveContains(needle)
        || thread.preview.localizedCaseInsensitiveContains(needle)
        // 不搜索 steps/turns 的内容
    }
}
```

如果用户之前在某个任务中讨论过"token 指标"，现在搜索"token"找不到那个任务。搜索只匹配标题和预览，而预览大多数情况下是工具调用文本。

### 修复

```swift
// 搜索时也匹配 steps 的文本内容
thread.task?.steps.contains(where: { step in
    step.text.localizedCaseInsensitiveContains(needle)
}) == true
```

---

<a name="ux11"></a>
## 🟢 UX 11：审查阶段的 diff 计算重复

**位置：** `ChatDetailView.swift:2015-2035` 和 `1819-1881`
**严重性：** **低**

### 问题

`ChatDetailView` 中有**两套独立的 diff 计算逻辑**：

1. `ReviewCard.simpleDiff(old:new:)`（行 1819）——用于复制到剪贴板
2. `DiffPreviewCard.computeDiff()`（行 2015）——用于屏幕显示

两套逻辑不一致：`simpleDiff` 是复杂的自定义算法（有 bug），`computeDiff` 是简单的逐行对比（无分组）。用户复制出去的 diff 和屏幕看到的 diff 可能不同。

### 修复

统一使用一套 diff 引擎，屏幕预览和复制共用同一份计算结果。

---

<a name="ux12"></a>
## 🟢 UX 12：流式输出中长回复 UI 卡顿

**位置：** `AppStore.swift` — `appendStreamDelta`
**严重性：** **低**

### 问题

流式输出时，每个 chunk 都触发：
```swift
// 更新 step.text → 触发 TaskStep 的 didSet
// → 更新 TaskStepCard → 更新 TextOutputCard → 更新 MarkdownText
// → AttributedString 重新解析整个 markdown
```

对于长回复（>10000 字符），每次更新都重新解析整个 Markdown、重新计算布局。当 LLM 输出速率高（>50 tokens/s）时，UI 更新频率超出渲染能力，导致滚动卡顿、文字闪烁。

### 修复

```swift
// 方案 1：降低刷新频率 —— 只在 flush 时更新 UI，而非每个 chunk
// 已在 streamBuffers 中实现（96 字符 / 0.14s），但可以增加
// 一个"大 chunk 跳过 UI 更新"的节流

// 方案 2：使用 Text(viewModel.displayText) 而非 AttributedString
// 对未完成的流式输出段，暂时使用纯文本渲染，完成后再解析 Markdown

// 方案 3：在 flush 时只更新插入文字，不替换整个 AttributedString
```

---

<a name="ux13"></a>
## 🟢 UX 13：任务卡片中的"记忆药丸"过于技术化

**位置：** `ChatDetailView.swift:1130-1157`
**严重性：** **低**

### 问题

```swift
private var memoryPills: [String] {
    var pills: [String] = []
    // "已读 .../Sources/App.swift +2"
    // "已有索引"
    // "失败 shell.exec ×1"
    // "搜过 15 个模型对比…"
}
```

这些药丸是对开发者有价值的调试信息，但对用户来说是噪音：
- "已有索引"——用户不知道这是什么意思
- "失败 shell.exec ×1"——用户可能没注意到有失败
- "搜过 15 个模型对比…"——截断的搜索词，看不懂

### 修复

```swift
// 区分"用户可见"和"调试"模式
// 用户模式下只显示简单的进度摘要
// 调试/开发模式下才显示详细药丸
```

---

<a name="ux14"></a>
## 🟢 UX 14：审查卡片的 riskLabel 硬编码关键词

**位置：** `ChatDetailView.swift:1797-1803`
**严重性：** **低**

### 问题

```swift
private func riskLabel(for path: String) -> String {
    let lower = path.lowercased()
    if lower.contains(".env") || lower.contains(".ssh") || lower.contains("key") || lower.contains("secret") {
        return "敏感路径，将被拦截"
    }
    return "批准后才会写入磁盘"
}
```

关键词检查太粗放：
- 文件名包含 `key` 就标为敏感，例如 `keyboard.swift`、`monkey.png` 都算
- 实际在 `SecurityEngine.swift` 中 deny list 更精确（`.env`, `credentials`, `secrets`, `.ssh`, `id_rsa`, `id_ed25519`, `.pem`, `.key`），但 UI 这里用了不同的更宽松的判断

### 修复

```swift
// 复用 SecurityEngine 的 deny list 判断逻辑
private func riskLabel(for path: String) -> String {
    SecurityManager.denyList.contains { path.contains($0) }
        ? "敏感路径，将被拦截"
        : "批准后才会写入磁盘"
}
```

---

<a name="ux15"></a>
## 🟢 UX 15：右侧面板的"资源"标签永远为空

**位置：** `WorkbenchView.swift:1472-1491`
**严重性：** **低**

### 问题

```swift
private struct ResourcesPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpace.md) {
            Text("资源")
            VStack(spacing: AppSpace.sm) {
                Image(systemName: "folder")
                Text("暂无资源")
            }
        }
    }
}
```

"资源"面板永远显示"暂无资源"。既然没有任何功能，这个标签页应该移除或隐藏。它占据了一个 Tab Bar 位置，用户每次点击都会看到空状态。

### 修复

```swift
// 隐藏，等有功能再显示
// 或者移除 WorkbenchTab.resources 枚举
```

---

<a name="ux16"></a>
## 🟢 UX 16：设计系统不一致——大量硬编码值

**位置：** 所有 View 文件
**严重性：** **低**

### 问题

`LaicaiTheme.swift` 定义了完整的设计系统，但许多代码直接使用硬编码值：

```swift
// 使用设计 token（好）
.padding(.horizontal, AppSpace.xl)
.foregroundStyle(TextGrade.primary)

// 硬编码值（不好）
.font(.system(size: 9, weight: .semibold))  // 出现 10+ 次
.frame(width: 24, height: 24)  // 出现 8+ 次
.frame(width: 22, height: 22)  // 3 次
.padding(.horizontal, AppSpace.sm + 1)  // +1 偏移
.padding(.horizontal, AppSpace.sm + 2)  // +2 偏移
.font(.system(size: 11, weight: .medium))  // IconButton 等
```

`AppFont` 没有包含所有需要的字号和字重，所以很多地方回退到 `Font.system(size: …, weight: …)`。`AppSpace` 的粒度过粗，导致大量 `+1`/`+2` 的微调。

### 修复

```swift
// 补充设计 token 缺失的值
extension AppFont {
    static let iconSystem = Font.system(size: 11, weight: .medium)
    static let stepCount = Font.system(size: 7, weight: .medium)
    static let badge = Font.system(size: 8, weight: .medium)
}

extension AppSpace {
    static let xxxs: CGFloat = 1
    static let xxl2: CGFloat = 32
}
```

---

<a name="ux17"></a>
## 🟢 UX 17：无"发送撤销"——发出后无法取消

**位置：** `AppStore.swift` — `sendDraft`
**严重性：** **低**

### 问题

用户按 `Enter` 或点击发送按钮后，消息立即创建为 userInput step，Agent 开始执行。此时：
- "发送"按钮变成"停止"——但停止的是 Agent 执行，已经发出的消息作为用户输入保留
- 用户如果打错了字或改变了主意，无法撤销
- 唯一的方法是手动删除步骤（但目前没有这个 UI 入口）

### 修复

```swift
// 在发送后的短暂窗口内（如 2 秒）提供"撤销"按钮
// 或点击"停止"时询问"是否也删除刚刚的输入"
```

---

## 汇总

| 优先级 | # | 问题 | 类型 |
|---|---|---|---|
| 🔴 P0 | 1 | 工具结果默认折叠不可见 | Bug |
| 🔴 P0 | 2 | 重复通知被静默丢弃 | Bug |
| 🔴 P0 | 3 | 启动时健康检查前 UI 闪烁 | Bug |
| 🟡 P1 | 4 | 自动滚动硬编码延迟不稳定 | Bug |
| 🟡 P1 | 5 | Diff 算法极端情况输出混乱 | Bug |
| 🟡 P1 | 6 | 焦点状态延迟一帧 | Bug |
| 🟠 P1 | 1 | 侧栏线程预览对任务无用 | UX |
| 🟠 P2 | 2 | 阶段进度条表达歧义 | UX |
| 🟠 P2 | 3 | 重试不在外面（藏菜单里） | UX |
| 🟠 P2 | 4 | 命令面板不支持键盘选择 | UX |
| 🟠 P2 | 5 | 快捷键冲突 | UX |
| 🟢 P3 | 6-17 | 其他 12 项 UX 问题 | UX |

### 快速修复（半天可完成）

1. 🔴 `Models.swift` — `isCollapsed` 默认改为 `false`
2. 🔴 `RootView.swift` — `onChange` 改用唯一 ID 检测
3. 🔴 `ComposerTextView.swift` — 移除多余的 `DispatchQueue.main.async`
4. 🟠 `LaicaiNativeApp.swift` — 将 `⇧⌘N` 用于新建线程，`⌘F` 保持系统行为
5. 🟠 `CommandPaletteView.swift` — 添加键盘导航
6. 🟢 `WorkbenchView.swift` — 移除"资源"空标签
7. 🟢 `ChatDetailView.swift` — 将"重试"外露为独立按钮

### 架构改进（1-2 天）

1. 统一 diff 引擎（移除 `simpleDiff` 中的两套逻辑）
2. 工具调用理由展示具体参数而非固定文案
3. 搜索功能扩展到步骤内容
4. 设计系统补齐缺失 token
