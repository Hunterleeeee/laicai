# 来财 (Laicai) 开发路线图

> 最后更新：2026-05-01
> 核心定位：本地 AI 编排中枢，不是聊天应用
> 竞争策略：模型弱 → 工具/编排必须强

---

## 剩余功能包快照（2026-04-30）

按用户可感知价值统计，当前还剩约 9 个大功能包、40 个左右可验收项：

1. 统一线程数据模型：合并 `ChatSession` / `AgentTask` 为单一 `Thread`，彻底消除直连与任务的状态割裂。
2. 任务流体验：工具调用轻量化、长任务阶段摘要、失败恢复建议、任务内追问更稳。
3. Token Economy 深化：长历史摘要、文件摘要缓存、工具结果压缩、超预算裁剪说明。
4. Wiki / Vault 完整闭环：recent results、web off 不联网、来源/diff/save 的最终验收。
5. Workflow / Skill 产品化：非法 YAML 清晰报错、Skill 发布、本地技能组合入口。
6. 后台个人智能层：菜单栏、全局快捷键、通知、后台任务、日报/周报、主动建议开关。
7. Claude Code / Codex 对标层：项目索引、计划-执行-验证骨架、任务 checkpoint、失败解释器、受控 patch workflow。
8. 质量与回归层：真实模型 smoke、UI 截图回归、connector 兼容矩阵、长任务/大项目压力测试。
9. 原生效率层：命令面板、拖拽附件、全局快捷键、多窗口、归档/导出、跨线程搜索。

当前优先级：先把“统一线程 + 任务流体验 + Token Economy”打磨到日常可用，再做后台主动智能。

本轮迭代已推进：任务流工具步骤改为轻量进度行，直连聊天历史增加最近上下文压缩与旧历史省略提示，减少续聊被旧任务带偏；意图路由升级为 `PlannerDecision`，开始记录路由原因、置信度和预计能力；任务与工作流增加折叠式完成检查，形成“规划 → 执行 → 自检”的 agent 骨架；新增任务状态解释器，任务内追问“为什么失败/什么情况”时直接基于当前步骤回答，不再误触发工具；新增 `workspace.index` 受控项目索引工具，整项目读取/优化类请求优先走索引而不是让模型自由拼 shell；新增 Shell Tool Policy，拦截 `find .`、`ls -R`、`tree` 等项目遍历命令并自动降级到受控索引；任务续聊路由改为语义判定，普通概念/产品问题不会因为当前选中任务而被硬拉进 agent；新增 Connector Capability Profile，Qwen API 不再被模型名误判成本地模型；项目指令读取覆盖 `AGENTS.md`、`CLAUDE.md`、`.cursor/rules`；续跑上下文加入结构化任务记忆，任务摘要展示已读文件、索引和失败工具；Failure Recovery 初版能真正执行 fallback 工具，而不是只显示恢复提示；供应商输出被 length 截断时会在同一任务里自动续写第二条；复杂任务增加可见 Plan / Execute / Verify / Summarize 纪律；空白新线程里的“刚才任务/被截断/上下文丢失”类追问会恢复最近任务，避免误建新线程。

本轮继续推进：`AppState` 增加权威 `selectedThreadID/source`，旧 `selectedSessionID/selectedTaskID` 变为兼容镜像；启动时开始读取并合并 SQLite `threads` 快照，`ThreadRecord` 不再只是只写快照；`TaskContext` 增加可持久化 `TaskMemory`，保存已读文件、搜索、失败工具、阶段结论、检查点和验证状态，续跑时注入 AgentLoop；文件写入审查增加最近一次已批准变更回滚能力，并记录审计。

本轮追加推进：新增用户挫败/纠错信号检测，遇到“胡说八道、没读、上下文没了、被截断、费 token”等反馈时进入证据优先修复模式，直接聊天和任务续跑都会收到对应提示；空白新线程里的挫败式上下文追问会优先恢复最近任务；结构化任务记忆补充未读候选和用户决策；侧栏搜索升级为统一线程搜索，可匹配任务步骤、工具名、工具参数和普通消息，不再只搜标题摘要。

本轮继续追加：任务完成后新增可折叠“证据清单”，稳定展示已建立索引、已读文件、已搜索内容、已运行命令、审查文件、失败工具和未验证项；工具调用卡片增加“原因”说明，让用户知道为什么用了索引、搜索、读取、shell、联网或写入审查。

稳定性追查追加：本机崩溃报告集中在 2026-04-29 11:34-11:45，堆栈落在 SwiftUI/AppKit display/layout cycle。已把 timeline 自动滚动改为合并后的非动画滚动，长 Markdown 回复默认折叠预览，避免超长文本持续参与布局；启动入口移除重复 `AppStore.live()` 初始化，并延后 connector 健康检查；connector 健康检查增加 in-flight 合并，减少启动、设置页、侧栏同时触发时的状态广播和布局刷新叠加。

卡顿优化追加：直连聊天流式输出增加缓冲刷新，避免每个 chunk 都更新侧栏摘要并写入 SQLite；最终回复完成后再落盘。Markdown 渲染结果改为状态缓存，只在文本或展开状态变化时重新解析，减少长回复滚动和输入框聚焦时的重复排版成本。

侧栏性能追加：侧栏线程列表改用轻量 `ThreadRecord` 摘要，不再在每次流式刷新时为所有线程重建完整 events；只有主 timeline、搜索命中内容和持久化快照需要完整事件流。

任务体验追加：长任务 timeline 默认只渲染最近 72 条步骤，早期历史折叠为摘要但不删除；软中断状态从“已取消/红色错误”调整为“已暂停/可继续”，减少误导用户以为上下文或任务丢失。

模型菜单追加：聊天框模型切换菜单开始展示本地/API、上下文窗口、工具能力和健康状态，并提供“测试当前模型”入口。

附件体验追加：Composer 附件从“把路径插进输入框”改为附件 chip，可选择多个文件/文件夹、移除、悬停查看路径；发送时自动拼接为读取附件指令，并进入背景信息预算估算。

命令面板追加：新增 `⌘K` 命令面板，可新建线程、继续当前任务、打开搜索、切换工作台、打开设置、测试当前模型、重试最近请求，并支持复制当前线程为 Markdown。
命令面板深化：`⌘K` 输入关键词时可搜索线程摘要并直接跳转，不再只是命令列表。
命令面板证据动作：当前任务可一键复制证据清单，包含已读文件、搜索、命令、审查文件、失败工具和验证状态。

导出追加：任务线程支持 JSON 导出，侧栏任务菜单补齐“导出 JSON”，聊天与任务都有可带走记录。

Patch Workflow 追加：审查卡片增加“复制 diff”动作，可在批准/拒绝前复制本次文件变更，便于人工审查和外部比对。

侧栏归档视图追加：侧栏增加一键隐藏已暂停/已完成线程的过滤按钮，先以视图层降噪替代破坏性归档迁移。

### 8 批次总计划状态

- [x] Phase 1 统一 Thread 数据模型：`AppState.threads: [Thread]` 为唯一数据源，`sessions`/`tasks` 为兼容计算属性；`ThreadRepository` 直接存取 `Thread`；`persistThreads()` 统一落盘；SQLite 自动从旧 session/task 表迁移；UI 全部通过 `Thread`/`ThreadRecord` 消费。
- [x] Phase 2 任务续跑与上下文记忆：截断多段合并展示已完成，续写步骤通过 continuationOf 链接到原始步骤，UI 自动合并显示。
- [x] Phase 3 Patch Workflow：写入走 review request，支持批准/拒绝、审计和按步骤批次回滚，UI 每个已批准步骤显示“回滚此变更”按钮。
- [x] Phase 4 Plan / Execute / Verify：阶段状态可交互（步骤计数和 tooltip）、验证命令自动选择、工具原因按阶段动态展示。
- [x] Phase 5 Workspace Map：模块地图、依赖热点、调用图推断、最近改动热点和测试覆盖关系已完成。
- [x] Phase 6 Token Economy：已支持上下文模式、预算估算、自动压缩提示和用量拆分；文件摘要缓存和裁剪明细持久化已完成。
- [x] Phase 7 UI / UX：Composer、模型、发送、附件、上下文预算已一体化；统一线程搜索；命令面板⌘K；拖拽附件已完成。
- [x] Phase 8 Wiki / Skill / 后台智能 / 质量回归：Wiki recent results、Skill 发布、后台个人智能、旧 Python/Electron 清理已完成；真实模型回归框架 `ModelRegressionRunner` 已实现（/regression 命令 + 设置页面板）；V0.1 smoke 测试脚本 `smoke_test.sh` 已就绪。
- [x] Phase 9 自我进化：8 层自进化闭环已完成。
  - L1 数据采集：`TaskOutcomeRecorder` 记录每次任务的 intent/iterations/status/tools/duration/rating。
  - L2 失败模式学习：`FailurePatternDB` 记录失败模式，新任务匹配时自动注入预防指令。
  - L3 Prompt A/B：`PromptRegistry` 版本跟踪、override、A/B 对比评分。
  - L4 路由漂移评估：`ResultEvaluator` 评分历史 outcome，`isRoutingMistake` 检测路由错误，`suggestRoutingAdjustment` 输出建议。
  - L5 用户行为信号学习：`BehaviorSignalTracker` 捕获取消/重试/纠错隐式反馈，自动生成 failure pattern + 预防指令写入 DB。
  - L6 Prompt 自动优化：`PromptRegistry.autoPromote()` 启动时自动对比版本评分，winner 自动升级。
  - L7 跨会话记忆沉淀：`TaskMemoryStore` 持久化已读文件/搜索/结论/文件摘要/关键词索引，新任务自动合并加载。
  - L8 路由纠偏闭环：`IntentRouter.applyRoutingDrift()` 每次路由决策都查历史 outcome，高取消率路由自动降低 confidence。

### 对标 Claude Code / Codex 缺口清单

- [x] 任务内状态解释：解释失败、进度、已读内容时不误调用工具。
- [x] 受控项目索引：`workspace.index` 返回文件树、语言分布、关键文件和目录样例。
- [x] 单一 Thread 数据模型：`Thread` 合并聊天、任务、工具事件、审查事件；`AppState.threads` 为唯一数据源；SQLite 统一持久化。
- [x] Workspace Map 初版：在索引基础上识别入口候选、测试候选、配置候选和路径风险热点。
- [x] Workspace Map 深化：识别模块边界、依赖关系、调用图、最近改动热点和测试覆盖关系。
- [x] Plan / Execute / Verify 初版：复杂任务有可见计划、执行纪律、验证阶段和总结，普通聊天降噪。
- [x] Plan / Execute / Verify 深化：阶段状态可交互、验证命令自动选择、最终回答强制带证据清单。
- [x] Checkpoint 续跑初版：失败/取消/迭代耗尽后自动生成“已完成、失败原因、下一步”，继续时注入最近 checkpoint。
- [x] Checkpoint 续跑深化：结构化记录已读文件、未读候选、验证状态、用户决策和下一阶段计划。
- [x] Patch Workflow：像 Codex 一样生成 patch、展示 diff、运行验证、支持回滚。
- [x] Failure Recovery Engine 初版：工具失败自动执行 fallback/改参数恢复，并把恢复结果喂回模型。
- [x] Failure Recovery Engine 深化：多级恢复计划、恢复成功后隐藏噪声失败、按工具类型给出更精细的降级路径。
- [x] Length Continuation：输出被供应商截断时自动在同一任务里续写第二条，不新建线程、不丢上下文。
- [x] Tool Policy 初版：根据任务语义选择工具，限制模型自由拼危险或低效 shell。
- [x] Tool Policy 深化：按任务阶段动态开放/关闭工具，并在 UI 展示“为什么选这个工具”。
- [x] Context Memory 初版：续跑上下文注入已读文件、搜索、失败工具、阶段结论，任务摘要展示记忆胶囊。
- [x] Context Memory 深化：持久化结构化记忆、记录未读候选、验证状态和用户决策。
- [x] Connector Capability Profile 深化：加入真实工具调用兼容、上下文长度、速度、稳定性探测。
- [x] Connector Capability Profile 初版：按连接器 kind/name/endpoint 判断本地/API，统一任务迭代、输出、相关文件预算，避免 API Qwen 被本地限流。
- [x] 项目指令读取初版：支持 `AGENTS.md`、`CLAUDE.md`、`.cursor/rules` 的优先级合并。
- [x] 项目指令读取深化：加入 README、包管理配置、子目录规则继承和冲突解释。
- [ ] 真实模型回归：覆盖 OpenAI-compatible、Ollama、Qwen API、DeepSeek API、本地代理。

---

## 当前交付计划（Native 主线）

### 产品原则

- Native macOS 是主线；Python/Electron 作为成熟能力参考和回归资产。
- 第一版先做到可安装、可打开、可配置模型、可日常聊天。
- 界面只说用户任务、结果和下一步，不暴露 `AgentLoop`、`Runtime`、`Function calling`、`Mock`、`Debug` 等开发术语。
- 外部 API 是可选模型后端；本机负责记忆、检索、压缩、权限、审计和回滚。
- 先可信闭环，再迁移 Wiki/Workflow/Skill，再做后台主动智能。

### Python/Electron 清理轨道

原则：Native 功能迁移一块，Python/Electron 旧实现就下线一块；生成物随时清，业务代码等 Swift 等价能力和验收测试到位后再删。

**立即清理**

- [x] 清理 `__pycache__`、`.pytest_cache`、`.DS_Store` 等本地生成物。
- [x] 清理根目录旧 PyInstaller / wheel / dmg 输出 `dist/`。
- [x] 清理旧 Electron 依赖 `node_modules/`。

**迁移后删除**

- [x] `electron/`：Native `.app` 安装、启动、配置、聊天验收稳定后删除。
- [x] `scripts/build_macos_app.sh`、`scripts/build_dmg.sh`：Native packaging 完全替代后删除。
- [x] `packaging/macos/` 旧安装说明与脚本：Native installer 文案替代后删除。
- [x] `src/harness/desktop/`：Native UI + runtime 对齐旧桌面能力后删除。
- [x] `tests/test_desktop_app.py`：Native UI/runtime 测试覆盖同等行为后删除。

**暂时保留**

- [ ] `src/harness/wiki.py`、`src/harness/rag/`、`src/harness/retrieval/`：V0.4 Vault + LLM Wiki 的迁移参照。
- [ ] `src/harness/agent/`、`src/harness/tools/`、`src/harness/workflow/`、`src/harness/skills/`：V0.2/V0.6 的迁移参照。
- [ ] `src/harness/adapters/llm/`、`src/harness/config/`、`src/harness/storage/`：模型配置、OpenAI-compatible API、会话存储的行为参照。
- [ ] Python tests：在对应 Native 单测/集成测试补齐前继续作为回归资产。

### V0.1 — 可安装、可用、像产品

**任务**

- [x] Native `typecheck.sh` 覆盖全部 Swift 源并稳定通过。
- [x] `.app` 能构建和启动，有正式 icon、名称、Info.plist 元信息。
- [x] 支持通过安装脚本打包安装到 `/Applications`，不可写时回退到 `~/Applications`。
- [x] 数据目录固定在 `~/Library/Application Support/Laicai`。
- [x] 设置页可配置 connector：endpoint、model、api key。
- [x] connector health check 可用。
- [ ] 能完成一次真实模型对话。
- [x] 首次启动不加载英文 sample 会话，不出现 demo/mock/preview response 文案。

**UI**

- [x] 首屏是工作台，不是演示页。
- [x] 空状态使用产品语言：`选择模型后开始`、`从一个任务开始`、`还没有会话`。
- [x] 顶部明确当前模型状态。
- [x] 错误提示给恢复动作，不显示内部堆栈。
- [x] assistant 消息渲染正常，无黑色长条。
- [x] 短会话进入后从顶部展示，长会话自动定位到底部。
- [x] 右侧活动区在无工具活动时展示当前对话/任务上下文，不再空白。
- [x] 消息操作可复制、可删除，侧栏摘要同步更新。
- [x] 侧栏展示项目概览卡：工作区、模式、任务/对话/模型数量。
- [x] 输入区展示当前上下文状态条：项目、模式、当前目标、模型。

**测试**

- [x] `native-macos/typecheck.sh`
- [x] `venv3/bin/python -m pytest -q`
- [ ] 手动 smoke：安装 → 启动 → 配置模型 → 发消息 → 重启 → 会话保留。
- [ ] UI smoke：Dock/Finder icon 正常，消息不重叠，输入框可聚焦。
- [x] 源码扫描：普通界面无 demo/mock/诊断类产品文案。

**验收**

- [ ] 可以作为日常 App 打开使用。
- [ ] 配置真实模型后能稳定问答。
- [ ] 重启后设置和会话保留。
- [x] 普通界面不出现开发术语。

### V0.2 — 本地 Agent 最小闭环

**任务**

- [x] `AgentLoop` 接入任务模式。
- [x] `code.search`、`file.read` 可用。
- [x] workspace path 生效。
- [x] 工具调用事件流进入任务界面。
- [x] 任务列表接入本地 SQLite 持久化，重启后不丢任务历史。
- [x] 工具结果压缩显示，最终回答不混入原始日志。
- [x] 最大迭代次数保护。

**UI**

- [x] 中间展示任务步骤：正在理解任务、正在搜索项目、已读取文件、任务完成。
- [x] 工具细节默认折叠。
- [x] 任务进入时顶部展示任务摘要卡：状态、步骤数、最近输出/错误。
- [x] 右侧在任务/对话不同场景展示对应上下文摘要。
- [x] 右侧展示 workspace、相关文件、模型和上下文摘要。
- [x] 任务 context 持久化到本地 SQLite，重启后保留工作区/分支/相关文件信息。

**测试**

- [x] 搜索存在文件。
- [x] 搜索不存在内容。
- [x] 读取小文件。
- [x] 大文件截断或拒绝。
- [x] workspace 为空时提示清楚。
- [x] 超过最大轮次时停止并说明。
- [ ] SwiftPM 测试执行：当前受本机 CommandLineTools `PlatformPath` 问题阻塞。

**验收**

- [x] 一句话能触发搜索和读取。
- [x] 过程可见但不吓人。
- [x] 失败步骤可定位。

### V0.3 — 可信执行

**任务**

- [x] `shell.exec` 白名单。
- [x] `file.write` 生成 review request，审批后才写入。
- [x] 拒绝后不写入。
- [x] `SecurityManager` 拦截敏感路径。
- [x] `AuditLog` 记录工具调用。
- [x] 命令失败显示 exit code 和 stderr 摘要。
- [x] 非 git 工作区调用 GitTool 时给出可继续的降级说明，不刷 `exit 128`。

**UI**

- [x] 审查面板显示文件、diff、风险、允许/拒绝。
- [x] 审计面板显示时间、操作、状态、结果摘要。

**测试**

- [x] 未审批前磁盘不变。
- [x] 审批后文件改变。
- [x] 拒绝后文件不变。
- [x] `pwd` 成功，`sudo` 被拒绝。
- [x] `.env`、`.ssh`、key 文件被拦截。
- [x] audit log 记录完整。

**验收**

- [x] 危险操作都可审查。
- [x] 所有本地操作可追溯。
- [x] 失败可解释、可重试。

### V0.4 — Vault + LLM Wiki

**任务**

- [x] Vault 路径配置、搜索、写入。
- [x] 迁移 Python 已有 LLM Wiki：preview、diff、save、source notes、web sources、recent results（Native 已有 preview/diff/save/source notes/web sources；recent results 已补）。
- [x] LLM 失败时生成 fallback draft。
- [x] Native `wiki.build` 工具：`save=false` 预览，`save=true` 写入 `03 Topics/topic.md`。
- [x] Wiki 来源支持本地 Vault notes，`useWeb=true` 时补充网页来源。
- [x] Native `web.fetch` 工具：读取用户给出的网页 URL，抽取标题和正文摘要。

**UI**

- [x] Wiki 面板展示 topic、preview、sources、diff、保存到 Vault。
- [x] preview 与 save 明确区分。
- [x] 不显示 `wiki_build_page` 等内部工具名。

**测试**

- [x] 临时 Vault + 一条 note 能生成 topic preview。
- [x] preview 不写文件。
- [x] save 后写入 `03 Topics/topic.md`。
- [x] 已有页面生成 diff 摘要。
- [x] web off 时不访问网络。
- [x] LLM 失败时 fallback 可用。

**验收**

- [x] 可以用它整理一个长期主题页。
- [x] 来源、diff、保存动作都清楚。

### V0.4.5 — 统一线程体验

**任务**

- [x] 左侧移除“任务 / 对话”二分入口，统一展示为线程列表。
- [x] 新建入口改为“新线程”，不再要求用户预判聊天或任务。
- [x] 线程列表混排普通回复、工具执行、工作流和 Wiki 产物。
- [x] 选择状态互斥：点击任务线程会清除会话选择，新线程会清除旧任务选择。
- [x] 新输入统一进入 Agent timeline，不再同时创建聊天会话副本。
- [x] 增加 `ThreadRecord` / `ThreadEvent` 适配层，UI 先面向统一线程。
- [x] 将 `ChatSession` 与 `AgentTask` 合并为单一 `Thread` 数据模型：`AppState.threads: [Thread]` 为唯一数据源，`sessions`/`tasks` 为兼容计算属性，SQLite 统一持久化并自动迁移旧表。
- [x] SQLite 增加统一 `threads` 快照表，为后续单一数据源迁移铺底。
- [x] 普通聊天也进入同一条 step timeline，而不是单独消息列表。
- [x] 工具调用、最终回复、审查请求都作为同一线程事件流持久化。
- [x] 失败线程的“重试”从当前线程恢复输入并创建新的执行线程。

**UI**

- [x] 首屏能力卡改成“一个入口 / 连续线程 / 工作流”。
- [x] Composer 状态不再显示“任务中 / 对话中”，改为线程状态。
- [x] 主区域统一 TimelineView，普通文本和工具步骤使用同一套呈现。
- [x] 右侧上下文按当前线程展示，不区分任务/对话面板。
- [x] 删除旧 `ChatMessagesView` / `TaskStreamView` 兼容组件。

**验收**

- [x] 用户输入任意一句话，不需要选择模式。
- [x] 简单问题像聊天一样快，复杂目标自然展开工具步骤。
- [x] 同一线程里可以从讨论升级到执行，再回到讨论。

### V0.5 — Token Economy

**任务**

- [x] `ContextMode`: 轻量 / 平衡 / 深度。
- [x] `TokenBudget`、`ContextAssembler`（已落地预算与上下文限流底座，assembler 继续细化）。
- [x] 工具 schema 按 intent 注入。
- [x] 任务模式确定性预搜索工作区，并自动读取首个高相关文件片段，先把真实代码线索喂给小模型，降低本地模型 function calling 决策负担。
- [x] 长历史摘要，文件摘要缓存，工具结果压缩（直连续聊历史已做紧凑注入，摘要缓存和工具结果预算裁剪已完成）。
- [x] 请求前 token 预估。

**UI**

- [x] 右侧显示预计输入 token、输出上限、当前模式、本次上下文项。
- [x] 超预算时说明裁剪了什么（已显示自动压缩策略和输入/项目/记忆/工具/附件/系统预留拆分，裁剪明细已完成）。

**测试**

- [x] chat 模式不发工具 schema。
- [x] task 模式只发相关工具。
- [x] task 模式会先执行工作区搜索，且实时网页任务不会误触发本地搜索。
- [x] 长历史被摘要。
- [x] 大文件只发摘要/片段。
- [x] 大量搜索结果被压缩。

**验收**

- [x] 外部 API 成本可见、可控、可预测。

### V0.6 — Workflow + Skill

**任务**

- [x] YAML workflow 加载。
- [x] step 输入输出传递。
- [x] 失败策略：abort / skip / retry。
- [x] skill registry。
- [x] 自然语言创建 skill draft。
- [x] skill 可组合 workflow。

**UI**

- [x] Workflow 面板展示可运行工作流、当前步骤、成功/失败、重试动作。
- [x] Skill 面板展示本地 skills、新建草稿、发布。

**测试**

- [x] 合法 YAML 加载。
- [x] 非法 YAML 报错清楚。
- [x] step A 输出给 step B。
- [x] abort/skip/retry 生效。
- [x] skill draft 不覆盖已有 skill。

**验收**

- [x] 重复任务能沉淀为本地工作流和 skill。

### V0.7 — 后台与个人智能层

**任务**

- [x] 菜单栏。
- [x] 全局快捷键。
- [x] 通知。
- [x] 后台任务。
- [x] 日报/周报。
- [x] 项目变化摘要。
- [x] 主动建议开关。

**UI**

- [x] 菜单栏状态简洁。
- [x] 通知可点击回到相关任务。
- [x] 主动建议不打断当前工作。

**测试**

- [x] 快捷键唤起。
- [x] 通知点击跳转。
- [x] 后台任务不重复执行。
- [x] 关闭主动建议后不再提示。

**验收**

- [x] 能常驻、不打扰、可关闭、可追溯。

---

## 第一部分：紧急修复（阻塞基本可用）

### 🔴 P0 — 不修就不能用

- [x] **助手消息黑色长条渲染 bug** — MarkdownText 已改为 SwiftUI Text + AttributedString 渲染，移除 NSTextView 黑块问题
- [x] **相对时间格式丑** — 已使用自定义 formatter：`刚刚` / `X分钟前` / `X小时前` / `昨天` / `MM-DD`
- [x] **旧 sample 英文数据残留** — 默认 sample 会话已清空，私人 connector 也不再硬编码进首启状态
- [x] **侧栏预览全是错误文案** — preview 在状态层归一化，错误 JSON/HTTP 失败不会进入侧栏长文本
- [x] **能力询问误进任务模式** — `你能生成视频吗？` 这类问题走普通聊天，具体执行请求才进入任务模式
- [x] **任务视图卡住会话切换** — 点击会话会清空当前任务选择，主区域切回会话内容

### 🟡 P1 — 严重影响体验

- [x] **用户消息蓝色气泡换行异常** — 聊天和任务用户气泡已加 maxWidth + fixedSize 换行约束
- [x] **右侧活动区信息层级弱** — 活动项已拆成状态、摘要、详情、时间，成功/失败有明确颜色
- [x] **错误时无修复路径** — 任务错误卡片提供重试和检查连接器入口
- [x] **输入框 focus 状态不明显** — NSTextView focus 回写 SwiftUI，边框/阴影和 placeholder 对比已增强
- [x] **任务流重复用户输入** — 本地任务步骤按 kind + text 去重，避免同一输入显示两次
- [x] **顶部更多菜单样式异常** — 修复 Menu label 被系统样式撑成灰色长条的问题
- [x] **设置页表单拥挤** — 设置窗口加宽，通用页改为稳定卡片表单，中文 label 不再折行
- [x] **可见文案偏工具说明** — 移除首屏/输入框里的快捷键说明和诊断面板字样

---

## 第二部分：数据模型重构（Agent 架构地基）

### Phase 0 — 类型系统

- [x] **定义 `TaskStep` 枚举**（替代 `ChatTurn`）
  - `.userInput(String)` — 用户原始输入
  - `.aiThinking(String, collapsible: Bool)` — AI 思考过程，可折叠
  - `.toolCall(id, name, params)` — 工具调用声明
  - `.toolResult(id, name, output, success: Bool)` — 工具执行结果
  - `.textOutput(String)` — AI 最终文本回复
  - `.error(String, recoverable: Bool, retryAction: String?)` — 错误 + 是否可重试 + 重试动作
  - `.reviewRequest(id, filePath, diff)` — 需要用户审查的文件修改
  - `.reviewResult(id, approved: Bool, userEdit: String?)` — 用户审查结果

- [x] **定义 `Task` 模型**（替代 `ChatSession`）
  - `id: UUID`
  - `title: String` — 任务标题（自动生成或用户指定）
  - `status: TaskStatus` — `.queued` / `.running` / `.waitingReview` / `.completed` / `.failed`
  - `steps: [TaskStep]` — 执行步骤流
  - `createdAt / updatedAt: Date`
  - `connectorID: UUID` — 使用的连接器
  - `workflowName: String?` — 如果是工作流触发，记录工作流名
  - `context: TaskContext` — 项目上下文快照

- [x] **定义 `TaskContext` 模型**
  - `workspaceRoot: String` — 工作区根目录
  - `relevantFiles: [FileInfo]` — 自动识别的相关文件
  - `claudeMD: String?` — 项目记忆文件内容
  - `gitBranch: String?` — 当前 git 分支
  - `gitDiff: String?` — 当前未提交变更

- [x] **定义 `FileInfo` 模型**
  - `path: String` — 相对路径
  - `language: String` — 编程语言
  - `summary: String` — 文件前 N 行摘要
  - `lastModified: Date`

- [x] **定义 `TaskStatus` 枚举**
  - `.queued` — 排队中
  - `.running` — 执行中
  - `.waitingReview` — 等待用户审查
  - `.completed` — 已完成
  - `.failed` — 失败
  - `.cancelled` — 已取消

- [x] **定义 `Tool` 协议**
  ```swift
  protocol LaicaiTool {
      var name: String { get }
      var description: String { get }
      var parameterSchema: [String: Any] { get }  // JSON Schema
      func execute(params: [String: Any], context: TaskContext) async throws -> ToolResult
      func validate(result: ToolResult) -> Bool
  }
  ```

- [x] **定义 `ToolResult` 模型**
  - `output: String` — 文本输出
  - `data: [String: Any]?` — 结构化数据（如文件内容、diff）
  - `success: Bool`
  - `error: String?`

- [x] **定义 `FileDiff` 模型**
  - `filePath: String`
  - `hunks: [DiffHunk]` — diff 片段
  - `oldContent: String`
  - `newContent: String`

- [x] **定义 `DiffHunk` 模型**
  - `oldStart: Int, oldCount: Int`
  - `newStart: Int, newCount: Int`
  - `lines: [DiffLine]`

- [x] **定义 `DiffLine` 模型**
  - `type: DiffLineType` — `.context` / `.added` / `.removed`
  - `content: String`

---

## 第三部分：工具系统（Agent 的手和脚）

### Phase 1 — 初始工具集

- [x] **ReadFileTool** — 读取项目文件
  - 参数：`path: String`（相对路径）
  - 自动：如果 path 不精确，用文件索引模糊匹配
  - 验证：文件存在 + 可读

- [x] **WriteFileTool** — 写文件（带 diff 审查）
  - 参数：`path: String`, `content: String`
  - 自动：生成 diff，送入审查队列
  - 验证：语法检查（根据文件扩展名选 linter）
  - 安全：不在白名单目录外写文件

- [x] **ShellTool** — 执行终端命令
  - 参数：`command: String`, `timeout: Double`
  - 白名单：`ls`, `cat`, `git`, `npm`, `python`, `swift`, `xcodebuild` 等
  - 验证：退出码检查 + stderr 捕获
  - 安全：禁止 `rm -rf`, `sudo`, 管道到 shell
  - 已完成初版：禁止用 shell 递归生成项目清单，要求改用 `workspace.index` / `code.search` / `file.read`

- [x] **SearchTool** — 代码/文本搜索
  - 参数：`query: String`, `scope: SearchScope`（`.files` / `.content` / `.gitHistory`）
  - 实现：ripgrep (rg) 或 FileManager 递归遍历
  - 验证：结果为空时自动扩大搜索范围

- [x] **GitTool** — git 操作
  - 子命令：`diff`, `status`, `log`, `branch`, `commit`, `checkout`
  - commit 需要审查
  - 验证：检查 repo 状态

### Phase 1.5 — 工具结果验证框架

- [x] **ValidationEngine** — 统一的验证入口
  - `file.write` → 语法检查（JS: eslint, Python: pyflakes, Swift: swiftc -parse）
  - `shell.exec` → 退出码 + stderr
  - `git.commit` → 检查未暂存文件
  - `code.search` → 空结果自动扩大范围
  - 验证失败 → 自动重试（最多 2 次）或降级策略

---

## 第四部分：编排层（让弱模型也能做高级任务）

### Phase 2 — 意图路由 + 自动上下文

- [x] **IntentRouter 初版** — 用户输入分类
  - `.chat` — 简单问答，走聊天路径
  - `.task` — 需要工具执行，走编排路径
  - `.workflow` — 匹配到预置工作流，走工作流路径
  - 已完成：`PlannerDecision` 记录原因、置信度、能力预期；选中任务时用续接语义、指代和重叠关键词判断是否沿用任务
  - 待增强：引入更结构化的语义分类器和可解释的 skill/workflow 选择器

- [x] **AutoContextEngine** — 自动预加载上下文
  - 解析用户意图 → 推断需要哪些文件
  - 从 git diff / 文件索引定位相关文件
  - 自动加载项目 CLAUDE.md
  - 打包成结构化 prompt，模型不用自己"想"要读什么
  - 上下文窗口管理：总量超限时，按相关性排序截断

- [x] **PromptComposer** — 结构化 prompt 组装
  - 系统指令 + 项目上下文 + 相关文件 + 工具描述 + 用户输入
  - 不同步骤用不同 prompt 模板
  - 支持 mustache 式变量替换 `{{relevant_files}}`

### Phase 2.5 — 错误恢复

- [x] **ErrorRecoveryEngine** — 编排层自动处理错误
  - 工具调用失败 → 自动重试（换参数）
  - 模型输出格式错误 → 自动修复 prompt 重试
  - 连接器离线 → 自动切换备用连接器
  - 所有重试耗尽 → 生成人话错误 + 修复建议

---

## 第五部分：工作流引擎（预置流水线）

### Phase 3 — YAML 工作流

- [x] **WorkflowParser** — 解析 `.laicai/workflows/*.yaml`
  - 支持 steps 定义
  - 支持步骤间数据传递（`input_from: previous_step.output`）
  - 支持 `auto_context: true`（编排层自动推断参数）
  - 支持条件分支（`when: result.success`）
  - 支持循环（`for_each: file in changed_files`）

- [x] **StepExecutor** — 按顺序执行 workflow steps
  - 每步生成 `TaskStep` 记录
  - 步骤失败时按策略处理（`stop` / `skip` / `retry` / `fallback`）
  - 支持并行步骤（`parallel: true`）

- [x] **内置工作流**
  - `code-review.yaml` — 代码审查（收集 diff → 读相关文件 → AI 审查 → 格式化输出）
  - `test-gen.yaml` — 测试生成（读源文件 → 生成测试 → 运行测试 → 修复失败 → 再测）
  - `debug.yaml` — 错误诊断（读日志 → 定位文件 → 分析原因 → 建议修复）
  - `refactor.yaml` — 重构（读文件 → AI 方案 → 审查 → 应用 → 验证）
  - `doc-gen.yaml` — 文档生成（读代码 → 生成文档 → 审查 → 写入）
  - `translate.yaml` — i18n 翻译（读源文件 → 提取字符串 → 翻译 → 审查 → 写入）

---

## 第六部分：Skill Hub + 多模型路由

### Phase 4 — 技能生态

- [x] **SkillRegistry** — 技能注册表
  - 发现：扫描 `.laicai/skills/` + 内置技能
  - 安装：从 Git repo / URL 安装
  - 管理：启用/禁用/更新
  - 测试：每个技能有测试用例

- [x] **ModelRouter** — 多模型路由
  - 意图分类 → 小模型（Qwen3-4B）
  - 上下文摘要 → 中模型（Qwen3-8B）
  - 代码生成 → 强模型（Claude/GPT）
  - 格式化输出 → 小模型
  - 代码审查 → 强模型
  - 路由规则可配置（`.laicai/model-router.yaml`）

- [x] **SkillComposition** — 技能组合
  - Unix pipe 式：`/pipe review PR | fix issues | add tests`
  - Workflow chain：WorkflowChainRegistry 持久化 .laicai/chains.json
  - 批量执行：`/foreach file in *.swift: 审查代码`

- [x] **SkillHub UI** — 技能市场界面
  - 分类浏览（分析/编辑/执行/工作流/通用）+ 搜索
  - 技能详情 + 一键使用
  - 创建技能 + 发布到工作区
  - 测试覆盖展示

---

## 第七部分：UI 改造（从聊天到事件流）

### Phase 5 — 事件流 UI

- [x] **TaskStreamView** — 替代消息气泡列表
  - 用户输入：顶部，简洁
  - AI 思考：灰色，可折叠，默认收起
  - 工具调用：带图标（📄 读文件、🔧 执行命令、📝 写文件）
  - 工具结果：可折叠，显示关键输出
  - 审查请求：高亮卡片，diff 视图（红绿行对比）
  - 错误：红色，带"重试"按钮
  - 文本输出：Markdown 渲染

- [x] **ReviewPanel** — 文件修改审查面板
  - Diff 视图（红绿行对比）
  - Approve / Reject / Edit 按钮
  - Edit 模式：直接在 diff 上修改
  - 批量审查：一次审查多个文件修改

- [x] **TaskQueueView** — 任务队列（右侧 Workbench 一个 tab）
  - 运行中任务
  - 等待审查任务
  - 后台完成任务
  - 失败任务 + 重试按钮

- [x] **双模态切换** — 聊天模式 / 任务模式
  - 聊天模式：简单问答，无工具调用
  - 任务模式：完整事件流 + 工具 + 审查
  - 自动切换：IntentRouter 根据用户输入自动选模式
  - 手动切换：用户也可以强制选择

### Phase 5.5 — 侧边栏重构

- [x] **任务列表替代会话列表**
  - 每个任务显示：标题 + 状态图标 + 最后更新时间
  - 状态颜色：运行中=蓝、等待审查=橙、完成=绿、失败=红
  - 右键菜单：重试 / 复制命令 / 删除

- [x] **项目上下文面板**
  - 当前工作区路径
  - 文件树（可展开）
  - CLAUDE.md 内容（可编辑）
  - Git 状态

---

## 第八部分：安全模型

- [x] **工作区沙盒** — AI 只能操作指定工作区目录
- [x] **ShellTool 白名单与工具策略初版** — 只允许读/构建/测试/诊断命令，并拦截 shell 项目遍历
- [x] **写操作必须审查** — AI 不能直接覆盖文件
- [x] **权限分级** — 读=自动、写=审查、删=禁止（除非用户明确授权）
- [x] **操作日志** — 所有工具调用记录到审计日志
- [x] **Git Worktree 隔离** — 任务在独立 worktree 执行，不污染主分支

---

## 第九部分：持久化 + 跨设备

- [x] **任务状态本地持久化** — SQLite 存储
- [x] **CLAUDE.md 项目记忆** — 跟着版本控制走
- [x] **Skill 配置持久化** — 安装的技能 + 路由规则
- [x] **跨设备会话接力** — SessionTeleport 导出/导入 .laicai-teleport 文件（zlib 压缩）+ /export 命令 + 设置页面板

---

## 第十部分：CLI 支持

- [x] **`来财` 命令行入口** — `来财 "review this PR"`
- [x] **Pipe 支持** — `git diff | 来财 "review"`
- [x] **脚本化** — 批量任务、CI 集成
- [x] **`/schedule` 定时任务** — 类似 Claude Code Routines

---

## 开发顺序建议

```
紧急修复 (P0) ──→ Phase 0 (类型系统) ──→ Phase 1 (初始工具)
                                              │
                                              ├──→ Phase 1.5 (验证框架)
                                              │
                                              ├──→ Phase 2 (编排层)
                                              │       │
                                              │       ├──→ Phase 2.5 (错误恢复)
                                              │       │
                                              │       └──→ Phase 3 (工作流引擎)
                                              │               │
                                              │               └──→ Phase 4 (Skill Hub)
                                              │
                                              └──→ Phase 5 (UI 改造)
                                                      │
                                                      ├──→ Phase 5.5 (侧边栏)
                                                      │
                                                      └──→ Phase 6-10 (安全/持久化/CLI)
```

**关键路径**：P0 修复 → Phase 0 → Phase 1 → Phase 2 → Phase 5

Phase 3/4 可以在 Phase 5 之后并行推进。

---

## 品牌规范

- 产品名：**来财**（不是"来采"）
- Bundle Display Name：来财
- workspaceName：来财原生版
- 所有 UI 文案：中文
- 所有错误消息：人话中文（不抛原始 JSON/英文）
