# Desktop Product Roadmap

## Product Goal

把桌面端做成一个本地优先、聊天优先、可日用的 Agent 工作台，而不是一个只能发消息的 Electron 演示。

核心目标：

- 聊天是主入口
- Agent / Wiki / Web / Obsidian / API 是能力层
- 模型状态、错误恢复、历史会话、草稿、工具调用过程都要可见可控
- 整体体验参考 Codex / Claude / ChatGPT：克制、稳定、可长期使用

## Milestone 1: Desktop Truly Usable

### UI / UX

- 深色、克制、聊天优先主界面
- 弱侧栏 + 主聊天线程 + 底部输入区
- 会话切换 / 删除 / 搜索 / 高亮
- 输入框自动增高、草稿保存、快捷键
- 基础 Markdown 与代码块显示
- 模型状态与 runtime 状态清晰可见

### Reliability

- 启动恢复最近会话
- degraded mode 仍可看历史与切换会话
- 清晰错误提示与恢复路径
- Electron smoke / Python regression 全覆盖

## Milestone 2: Agent Workspace

### Agent Core

- 长任务分阶段推进
- 计划模式 / 分析模式 / 执行模式
- 工具调用前说明意图
- 工具调用过程可视化
- 工具结果总结与失败重试

### Interaction Style

- Claude 式任务推进：先理解、再拆解、再执行
- 可见过程摘要，而不是暴露原始 chain-of-thought
- 长任务 checkpoint 与进度更新

## Milestone 3: LLM Wiki + Obsidian

### Wiki

- 从聊天直接发起 `/wiki`
- 主题页 preview / save / update
- 展示 wiki 生成阶段进度
- 展示 vault sources 与 web sources
- 最近 wiki 任务与结果面板

### Obsidian

- 显示当前 vault 与健康状态
- 搜索本地笔记
- 打开对应 Obsidian 笔记
- 创建 / 更新笔记前预览 diff
- wiki / chat / note 之间互相跳转

## Milestone 4: Web / Research

### Web

- 搜索结果卡片化展示
- 页面抓取、摘要、引用
- 研究链路：搜索 -> 抓取 -> 归纳 -> 结论
- 联网开关与来源可见
- 研究结果一键写入 wiki 或笔记

## Milestone 5: API / Connectors

### Connectors

- OpenAI-compatible / Ollama / 外部 REST API
- connector 配置页
- API key / headers / base url 管理
- 测试连接与错误诊断
- Agent 自动决定是否调用 connector

## Milestone 6: Long-term Use

### Productivity

- 重试 / 停止生成 / 编辑后重发
- pin / archive / export / import
- 跨会话搜索
- 命令面板 / slash UI / workflow 面板
- 设置面板与主题/密度/字体配置

### Quality

- 后端 API regression
- renderer interaction regression
- Electron end-to-end smoke
- wiki / web / agent / obsidian integration smoke

## Full Backlog

### Desktop Shell

- 会话系统完整化
- 输入体验完整化
- Markdown / 代码展示增强
- 模型状态与诊断面板
- 导出导入与恢复

### Agent

- 工具调用可视化
- 分阶段计划与执行
- 失败重试与降级
- 过程摘要

### Wiki

- `/wiki`、`/wiki-save`、topic update
- preview / save / source cards / progress timeline

### Obsidian

- vault 状态
- note search / open / write / diff / jump

### Web

- search / fetch / research / citations / source drawer

### API

- connectors / credential management / health check / switching

### Quality

- tests / smoke / packaging / crash recovery
