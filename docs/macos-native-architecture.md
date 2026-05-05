# macOS 原生版架构方案

## 目标

基于当前 Harness Desktop 的能力，构建一个全原生的 macOS 应用，目标不是继续维护 Electron 版本，而是逐步替换为 Swift 原生产品。

## 架构原则

- UI、导航、状态管理、设置、窗口系统全部原生
- Agent/runtime 不再依赖 Electron IPC 或前端 JS 状态机
- 现有 Python 代码作为迁移期参考实现，不作为长期桌面主内核
- 迁移采用“可替换模块”策略，不做一次性推倒
- 首个原生版本优先可用性与稳定性，不优先 App Store

## 总体分层

### 1. Presentation 层
技术：`SwiftUI + AppKit`

职责：
- 三栏工作台
- 原生菜单与快捷键
- 原生弹窗、sheet、popover、sidebar
- 拖拽、截图、文件选择、导出
- 多窗口（后续扩展）

建议模块：
- `AppShell`
- `SidebarFeature`
- `ChatFeature`
- `WorkbenchFeature`
- `SettingsFeature`
- `WorkflowFeature`
- `SessionSearchFeature`

### 2. Application 层
技术：Swift

职责：
- 统一状态管理
- 命令编排
- session 生命周期
- connector 生命周期
- workflow 触发与结果回填
- 日志聚合
- 权限状态管理

建议模式：
- 单向数据流
- Feature reducer / store
- Async/await + actors

建议核心对象：
- `AppState`
- `SessionStore`
- `ModelStore`
- `WorkflowStore`
- `DiagnosticsStore`
- `PermissionStore`
- `RuntimeCoordinator`

### 3. Domain 层
技术：Swift

职责：
- 会话模型
- turn / tool call / tool result 规范
- workflow spec / result
- connector spec / health
- runtime events
- sprint contract

建议 value types：
- `ChatSession`
- `ChatTurn`
- `ToolInvocation`
- `ToolResultPayload`
- `WorkflowSpec`
- `WorkflowRun`
- `ConnectorProfile`
- `RuntimeEvent`

### 4. Infrastructure 层
技术：Swift + 少量系统框架

职责：
- SQLite 持久化
- 本地文件管理
- Screenshot API
- 网络请求
- 本地命令执行
- 日志写入
- 配置读写

建议组件：
- `SQLitePersistence`
- `ConnectorRepository`
- `SessionRepository`
- `WorkflowRepository`
- `AppConfigRepository`
- `ScreenshotService`
- `CommandExecutionService`
- `StructuredLogService`

### 5. Runtime 层
技术：Swift 优先，Python 迁移期兼容

职责：
- LLM 请求发送
- tool call 协议处理
- tools 注册与执行
- workflow 执行
- contract 生成与验证
- 上下文装配

长期目标：
- 将现有 `agent.loop`、tool registry、workflow executor、connector 切换能力迁移到 Swift

## 推荐迁移策略

采用双阶段 runtime 策略。

### 阶段 A：Native UI + Transitional Runtime
- 原生 SwiftUI 客户端完成
- Python runtime 保留为本地 sidecar
- Swift 通过本地协议与 Python 通信
- 目标：快速获得原生体验，降低产品风险

### 阶段 B：Native Runtime
- 将高价值路径逐步迁入 Swift：
  - chat orchestration
  - connector management
  - session persistence
  - workflow execution
  - runtime logs
- Python 仅保留少数工具适配，或彻底移除

如果你坚持“从第一天起就全栈原生”，也可以，但开发风险和调试成本会明显上升。

## 原生版状态管理建议

采用 feature-based store，不建议在全局 view model 上堆逻辑。

### 顶层状态
- `appShell`
- `navigation`
- `sessions`
- `chat`
- `connectors`
- `workflows`
- `diagnostics`
- `settings`
- `permissions`

### 关键派生状态
- 当前活动 session
- 当前活动 connector
- 当前模型运行状态
- 当前 workflow run
- 当前右栏 tab
- 当前错误恢复建议

## 数据存储建议

### 本地数据库
建议：`SQLite + GRDB`

理由：
- 结构清晰
- 易迁移现有 session/event 模型
- 更适合日志、turn、tool call、workflow history
- 比 Core Data 更容易掌控协议与导出

### 文件存储
建议目录：
- `~/Library/Application Support/Laicai/`
  - `config/`
  - `sessions/`（如需导出缓存）
  - `logs/`
  - `artifacts/`
  - `screenshots/`
  - `workflows/`（用户级）

### 配置拆分
- `app-config.json`：UI/偏好/权限记忆
- `connectors.json`：模型配置
- `workspaces.json`：工作区/Vault 根目录

## 关键系统模块设计

### 会话系统
替代当前前端+SQLite 混合状态。

能力：
- 创建/切换/删除/克隆
- pin/archive/favorite
- 搜索
- 分组
- 预览生成
- 导出

### Connector 系统
能力：
- 保存多个 connector profile
- health check
- 实际 chat compatibility test
- 热切换
- 错误解释
- 最近使用排序

### Chat Runtime
能力：
- 文本生成
- streaming
- tool call / tool result 对话协议
- 失败自动恢复
- stop/cancel
- usage 统计

### Workflow Runtime
能力：
- 发现 workflows
- 运行 workflow
- 显示契约
- 记录 artifact
- 结果回填聊天上下文

### Diagnostics / Logs
能力：
- command
- tool_call
- progress
- error
- filter / search / export

## 权限与系统集成

### 必须处理
- 截图权限
- 文件读写权限
- 网络访问
- 自动化/命令执行的用户预期管理

### 建议策略
- 首次使用时渐进申请
- 不在首次启动一次性索要全部权限
- 每个权限请求都说明用途

## 打包与发布

### 推荐首发
- 站外签名发布
- notarized `.app` / `.dmg`
- 不以 App Store 为首发目标

### 原因
当前产品能力与沙盒限制冲突较多：
- 本地命令执行
- 文件系统访问
- 外部工具/模型调用
- 截图/自动化能力

## 迁移映射

### 当前 Electron 能力 → 原生模块
- `electron/main.js` → `AppShell + WindowCoordinator`
- `preload.js` → 原生 command/event bridge
- `desktop/assets/app.js` → 各 SwiftUI feature views
- `desktop/server.py` → 迁移期 local bridge / 长期 Swift runtime services
- `desktop/app.py` → `RuntimeCoordinator + Feature stores + Services`

## 第一阶段落地建议

### 目标
做出一个“看起来已经是产品”的原生版本，而不是技术验证壳。

### 范围
- 原生三栏界面
- 会话系统
- 聊天主流程
- connector 切换
- 工具动作展示
- workflow 基础面板
- 设置

### 暂缓
- 多窗口联动
- 深度主题系统
- 复杂布局自定义
- 全量 Python 能力迁移

## 风险点

### 1. Runtime 一次性全迁风险高
建议保留过渡层，不要 Day 1 全盘重写。

### 2. Connector 协议差异复杂
不同 OpenAI-compatible 服务对 tools、temperature、token 参数兼容性不同，需要抽象兼容层。

### 3. 原生 UI 容易做成“更漂亮的 demo”
必须以主路径成功率为目标，而不是先做视觉皮肤。

## 开发顺序建议

### Step 1
完成原生 UX 方案与架构方案

### Step 2
建立 Swift 原生工程与基础模块划分

### Step 3
实现会话 + 聊天 + connector 三个核心 feature

### Step 4
接入 workflow / logs / screenshot / settings

### Step 5
清理 Electron 依赖，进入迁移发布阶段

## 结论

这个项目应被视为：
- 一个新的 macOS 原生应用建设工程
- 而不是当前 Electron 页面的小范围替换

现有代码的价值主要在：
- 业务规则
- 数据结构
- runtime 经验
- connector/tool/workflow 协议积累

后续应按“原生产品”思路推进，而不是继续补旧桌面壳。
