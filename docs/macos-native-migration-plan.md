# macOS 原生版迁移计划

## 目标

将当前 Electron 桌面版逐步迁移为全原生 macOS 产品，避免双线长期失控，同时确保已有用户能够平滑过渡。

## 迁移原则

- 原生版优先承接主路径，不追求首日功能全覆盖
- 旧版继续维持可用，但不再承载新的交互方向
- 迁移按能力切片推进，不做“大爆炸切换”
- 每一阶段都必须有可验收的用户收益

## 当前基线

### Electron 现状
- 已有完整聊天、connector、workflow、日志与会话能力
- UI 与交互负担较重，整体体验仍偏 demo
- 后端能力与协议经验有较强复用价值

### Native 当前进度
- 已建立 `native-macos/` 工程目录
- 已有 SwiftUI 三栏壳
- 已有 AppState / AppStore / runtime boundary / repository boundary
- 已有 JSON 落盘基础能力
- 已有会话、模型切换、右栏工作台、设置等第一层骨架

## 分阶段计划

### 阶段 0：基础工程冻结点
目标：建立原生基座，禁止继续在 Electron 上做大规模交互返工。

完成标准：
- 原生工程目录稳定
- 三栏结构稳定
- 新的信息架构固定
- 原生版成为后续 UX 演进主线

当前状态：已开始，接近完成。

### 阶段 1：聊天主路径替换
目标：让原生版先承接最高频路径。

范围：
- 会话列表与切换
- 聊天消息流
- 输入框与发送/停止
- 模型切换
- 基础错误提示
- 工具动作摘要

验收：
- 用户可以在原生版完成一次完整问答
- 模型切换可见、可用、可恢复
- 工具调用不污染正文消息流

风险：
- Swift runtime 尚未接管时，需要过渡 runtime bridge

### 阶段 2：connector 与状态持久化替换
目标：把原生版从“会跑”提升到“可长期使用”。

范围：
- connector 管理面板
- connector health check
- 实际 chat compatibility test
- session/connectors/settings 持久化
- 最近使用排序
- 基础导入旧配置

验收：
- 关闭重开后会话与 connector 状态保留
- 常见 connector 切换路径可用
- 错误提示可指向恢复动作

### 阶段 3：workflow / workbench / diagnostics 接管
目标：把旧版高阶能力迁入原生产品。

范围：
- workflow 列表与运行
- workbench 右栏结构化上下文
- logs / diagnostics
- artifacts / screenshot / export

验收：
- 右栏成为有效工作台，而不是调试垃圾桶
- workflow 运行结果能回填聊天上下文
- 错误、命令、工具链路都可追踪

### 阶段 4：Swift runtime 替换核心编排
目标：逐步脱离 Python/Electron 运行时依赖。

优先迁移：
- chat orchestration
- tool call / tool result 协议
- connector compatibility fallback
- session event logging

后迁移：
- workflow executor
- context assembly
- screenshot/tool adapters

验收：
- 核心聊天与工具路径不再依赖 Electron
- 关键协议链路由 Swift 主导
- 回归测试覆盖主要 connector 兼容性

### 阶段 5：发布切换与旧版退场
目标：完成默认入口切换。

范围：
- 原生版成为默认桌面入口
- Electron 版进入维护/兼容模式
- 提供配置迁移与会话导入
- 明确 deprecation 节奏

验收：
- 新用户默认下载原生版
- 旧用户迁移成本可控
- 已知阻塞能力有明确替代路径

## 迁移映射表

### 会话系统
- Electron：前端状态 + SQLite
- Native：`AppStore + SessionRepository + 持久化存储`

### 模型/connector
- Electron：header switcher + settings + workspace catalog
- Native：顶部模型切换 + connector repository + 原生设置页

### 聊天运行时
- Electron：`desktop/app.py` 驱动
- Native：`ChatRuntimeClient` 边界，先 mock/bridge，后 Swift 原生实现

### workflow
- Electron：Python executor + 侧边入口
- Native：右栏工作台 workflow panel + Swift runtime adapter

### 日志/诊断
- Electron：调试面板式暴露
- Native：结构化 logs/workbench，默认降噪

## 配置迁移建议

首批只迁移三类数据：
- connectors
- sessions
- user settings

来源：
- `~/Library/Application Support/Laicai/.harness.toml`
- workspace `desktop-connectors.json`
- 旧 session store

策略：
- 首次启动原生版时检测旧数据
- 给用户一个明确的“导入旧桌面配置”动作
- 不做静默覆盖

## 风险控制

### 风险 1：双端行为不一致
措施：
- 以协议测试覆盖 connector/tool call 行为
- 将关键兼容规则写进 Swift runtime 层

### 风险 2：原生版沦为漂亮壳
措施：
- 每阶段都要求真实可用能力，而不是只交视觉
- 主路径优先于高级功能

### 风险 3：迁移周期过长
措施：
- 严格分阶段发布
- Electron 只保守维护，不做新方向投入

## 推荐里程碑

### Milestone A
- 原生壳可运行
- 三栏布局稳定
- 聊天主路径打通

### Milestone B
- connector 与 session 持久化完成
- 设置与工作区接入完成

### Milestone C
- workflow 与 diagnostics 基本可用
- 原生版进入内测主线

### Milestone D
- Swift runtime 接管核心聊天路径
- Electron 降级为兼容版本

## 结论

迁移目标不是“复制一个 Electron 版”，而是：
- 用原生 macOS 产品重新承接用户主路径
- 用更清晰的复杂度分层承接 connector/tool/workflow 能力
- 最终让 Electron 退出主舞台
