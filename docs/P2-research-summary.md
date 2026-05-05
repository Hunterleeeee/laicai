# P2 调研总结：NLAH 与 Aider 多模型切换

## P2-1: NLAH (Natural-Language Agent Harnesses) 配置语法调研

### 核心概念
- **NLAH**: 用可编辑的自然语言表达 Agent 控制逻辑，而非硬编码的 Python 脚本
- **IHR (Intelligent Harness Runtime)**: 解释并执行 NLAH 的运行时环境
- **显式契约 (Explicit Contracts)**: Agent 将状态写入持久化文件（如 manifest.json）
- **持久化工件 (Durable Artifacts)**: 文件系统作为内存架构

### NLAH 配置结构
```
Role Boundaries:      定义 Agent 的权限边界
State Semantics:      如何记忆过去行为和存储当前上下文
Failure Handling:     工具失败或推理遇到死胡同时的处理逻辑
Runtime Adapters:     与外部环境、数据库、API 的接口
```

### 状态管理
- 不依赖 LLM 上下文窗口（会随时间退化）
- 通过文件系统显式定义状态约定
- `/memory/active_session/` 目录作为可靠的记忆轨迹

### Harness 演进可行性评估
**当前 Harness 实现:**
- ✅ Workflow: frontmatter + markdown 步骤列表
- ✅ Contract 生成：Sprint 契约已在执行前自动生成
- ✅ 状态存储：session metadata 存储契约、事件、wiki 结果
- ⚠️ 差距：尚未完全使用自然语言作为控制逻辑，仍是结构化配置

**向 NLAH 演进的建议:**
1. 将 Workflow 步骤从结构化 JSON 转为自然语言指令
2. 增加文件系统持久化状态根目录
3. 实现 IHR 风格的 In-Loop LLM 连续读取 harness 并决定下一步
4. 显式契约可扩展为 markdown 格式的 "manifest.md"

---

## P2-2: Aider 多模型切换对比分析

### Aider 的多模型架构
```
Main Model (Architect):     /model 命令设置，负责架构设计
Editor Model:               --editor-model 设置，负责生成文件编辑指令
Weak Model:                 轻量级任务（如提交信息生成）
```

### 关键能力
1. **Architect 模式**: 主模型提出方案 → Editor 模型转为具体编辑
2. **热切换**: `/model` 命令可在聊天中切换模型
3. **智能配对**: 内置默认根据主模型选择 Editor 模型
4. **编辑格式**: editor-diff、editor-whole 等多种格式

### 当前 Harness 差距分析
**已实现:**
- ✅ Connector catalog 支持多配置保存
- ✅ 前端切换按钮可热切换模型
- ✅ `_recreate_llm_and_agent()` 热重建机制

**待优化:**
- ❌ 无 Architect/Editor 模型分离
- ❌ 切换时上下文可能丢失（需验证）
- ❌ 无内置模型配对推荐
- ❌ 切换时无状态保持提示

### 优化建议
1. **模型角色分离**: 增加 `architect_model` 和 `editor_model` 配置
2. **智能配对**: 内置映射表（如 o1 → GPT-4o editor）
3. **状态保持**: 切换时提示用户上下文是否保留
4. **快捷键**: `/model` 命令支持聊天内快速切换

---

## 结论
- P2-1: Harness 已在向 NLAH 方向演进（契约、持久化工件），下一步可将 Workflow 配置完全自然语言化
- P2-2: 当前 connector 热切换已实现基础功能，可参考 Aider 增加 Architect/Editor 分离和智能配对
