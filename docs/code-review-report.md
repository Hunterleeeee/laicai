# 来财 (Laicai) 项目代码审查报告

审查日期：2026-05-01
审查范围：`src/harness/` 全部 60+ 个 Python 源文件、`tests/`、配置及文档

---

## 项目概况

来财是一个本地优先的 AI Agent 工作空间，围绕 Ollama + Obsidian 知识库构建。核心架构：

- **CLI** (`laicai` / `laicai chat`) 作为统一入口
- **Agent** 新系统：`agent/loop.py` + `OpenAICompatLLM`（异步、流式）
- **Orchestrator** 旧系统：`orchestrator/engine.py` + `LocalModelRuntime`（同步、已弃用）
- **Vault**：与 Obsidian 笔记库集成的适配器
- **Skills**：基于文件夹的技能系统（skill.json + prompt.md）
- **Memory**：基于正则的知识提取 + SQLite 持久化
- **RAG**：TF-IDF 关键词搜索 + 可选向量语义搜索
- **Web**：HTTP 抓取 + Playwright 浏览器自动化

---

## 一、严重问题

### 1. 两套并行的 LLM 后端 — 维护成本高

**影响：高**

项目维护着 **两套完全独立的 LLM 调用栈**：

| | 新系统 (推荐) | 旧系统 (已弃用) |
|---|---|---|
| 文件 | `adapters/llm/openai_compat.py` | `models/runtime.py` |
| 接口 | `async` / httpx | sync / urllib |
| 流式 | ✅ 支持 | ❌ 不支持 |
| 工具调用 | ✅ OpenAI 函数调用格式 | ❌ 纯文本 prompt |
| 使用方 | `agent/loop.py` (REPL) | `orchestrator/engine.py`, `skills/runner.py`, 所有 legacy CLI |

旧系统 `LocalModelRuntime.complete()` 里还有复杂的重试逻辑（先试 OpenAI 格式，失败后降级到 Ollama 原生 API；再尝试不同 token budget），这些逻辑应该在上层处理，而不是混在模型调用层。

**建议**：彻底移除 `models/runtime.py`，让所有代码都走 `OpenAICompatLLM`。

---

### 2. Python 代码执行沙箱可绕过

**影响：高** | **文件：** `agent/code_runner.py`

`_BANNED_IMPORTS` 黑名单存在绕过方式：

```python
_BANNED_IMPORTS = {
    "os", "subprocess", "sys", "socket", "urllib", "http",
    "ftplib", "pickle", "marshal", "ctypes", "multiprocessing",
}
```

绕过方法：
- `import importlib; importlib.import_module("os")` — `importlib` 未封禁
- `__builtins__.__dict__["__import__"]("os")` — `__builtins__` 未封禁
- `__import__("os")` 函数调用被 AST 检测，但 `getattr(__builtins__, "__import__")` 可绕过

代码在临时目录运行但**没有容器隔离**——可以读写文件、建立网络连接、访问环境变量。

**建议**：对不可信的代码执行应采用真正的容器化（Docker/Podman），或至少使用 `pyodide` / `pocketc` 等隔离方案。

---

### 3. 磁盘索引缓存存储完整向量 — 数据膨胀风险

**影响：中** | **文件：** `rag/vector_index.py`

`_save_cache()` 将完整向量数据写入 JSON 文件。对于 500 篇笔记、768 维向量，缓存文件约 500×768×8 ≈ 3MB JSON。每次重建都会完整写入一次。

向量数据是浮点数数组，JSON 文本格式体积大且解析慢。

**建议**：使用 `numpy.savez` 或 `pickle`（如果安全），或者逐增量更新。

---

### 4. 覆盖式测试严重不足

**影响：高**

存在测试文件的模块：`test_planner`、`test_chunker`、`test_state`、`test_retrieval`、`test_intent_router`、`test_workflow`

**完全没有测试的核心模块：**

| 模块 | 功能 | 行数 |
|---|---|---|
| `agent/loop.py` | Agent 主循环 | ~330 |
| `agent/tools.py` | 工具注册 | ~100 |
| `agent/builtin_tools.py` | 内置工具 | ~250 |
| `agent/code_runner.py` | 代码沙箱 | ~110 |
| `adapters/llm/openai_compat.py` | LLM 适配器 | ~310 |
| `adapters/embedding.py` | 嵌入适配器 | ~110 |
| `adapters/storage.py` | 会话持久化 | ~140 |
| `cli/chat.py` | 交互式 REPL | ~530 |
| `cli/main.py` | CLI 入口 | ~115 |
| `skills/loader.py` | 技能加载 | ~165 |
| `skills/runner.py` | 技能运行 | ~240 |
| `vault/obsidian.py` | Obsidian 集成 | ~105 |
| `wiki.py` | Wiki 构建 | ~350 |
| `memory/*.py` | 记忆系统 | ~150 |

未测试的行数总计约 **3000 行**，占总代码量的 ~70%+。

---

## 二、中等严重问题

### 5. VaultIndex 每次搜索都全局扫描文件系统

**影响：中** | **文件：** `rag/index.py`

`_refresh_cache()` 对知识库中**每个 .md 文件**都执行 `stat()` 检查 mtime。对于大知识库（数千文件）和频繁搜索的场景，这可能成为性能瓶颈。且没有持久化缓存，每次进程重启都需重建。

**建议**：将文件 mtime 缓存持久化到磁盘（SQLite 或 JSON），或者监听文件系统事件（`watchdog`）。

---

### 6. `SQLiteSessionStore.save_session()` 非原子性删除重插

**影响：中** | **文件：** `adapters/storage.py:88`

```python
conn.execute("DELETE FROM turns WHERE session_id = ?", (session.id,))
for t in session.turns:
    conn.execute("INSERT INTO turns ...")
```

如果 `DELETE` 之后、`INSERT` 完成之前进程崩溃，会话数据会丢失。应在事务中执行，或使用 `INSERT OR REPLACE` + 唯一约束。

---

### 7. 两套独立的会话存储

**影响：中**

`StateStore` (SQLite, `harness.db`) 和 `SQLiteSessionStore` (SQLite, `sessions.db`) 是**完全独立**的：

| | StateStore | SQLiteSessionStore |
|---|---|---|
| 表 | sessions, turns, artifacts, documents, ... | sessions, turns |
| 使用方 | Orchestrator (deprecated) | Agent (当前) |
| 存储位置 | `data/memory/harness.db` | `support dir / data/memory/sessions.db` |

**没有共享数据**，这意味着用户可能在 `laicai chat` 中进行的对话，其他 CLI 命令完全看不到。

---

### 8. `ContextAssembler` — 完整的死代码

**影响：低** | **文件：** `retrieval/context.py`

`ContextAssembler` 实现了多源上下文检索（知识库、会话历史、语义搜索、收藏消息、Wiki 结果），约 300 行代码。**但从未被 Agent 或 Orchestrator 引用或导入**。这是开发过程中被弃用的功能，但代码没有清理。

---

### 9. API 密钥明文存储

**影响：中** | **文件：** `config/loader.py`

`ModelConfig.api_key` 存储在 `.harness.toml` 中。虽然有 `api_key_env` 的环境变量方案，但默认配置直接使用明文。示例配置中也包含 `api_key = "ollama"`。

---

## 三、低严重问题

### 10. 文件名时间戳冲突（毫秒级）

**文件：** `vault/obsidian.py:75`

```python
filename = f"{datetime.now().strftime('%Y%m%d-%H%M%S')}-{slugify(title)}.md"
```

同一秒内创建同标题笔记会覆盖文件。应添加 UUID 或微秒后缀。

---

### 11. `_compat_retry_bodies` 试探性重试会吞掉真实错误

**文件：** `adapters/llm/openai_compat.py:152-177`

当 API 返回 400 错误时，会自动尝试多种 body 变体（去掉 tools、去掉 temperature、改 max_completion_tokens）。这可能把有意义的错误信息变成"最终返回 200 但结果不对"的静默失败。

---

### 12. `render_config_toml` 字符串拼接可能产生非法 TOML

**文件：** `config/loader.py:400-451`

手动字符串拼接生成 TOML，虽然对常见路径做了转义，但遇到路径中的特殊字符（换行符、控制字符）可能产生非法输出。建议使用 `tomli_w` 库。

---

### 13. `pyproject.toml` 引用了不存在的包

```toml
[tool.setuptools.package-data]
"harness.desktop" = ["assets/*.css", "assets/*.html", "assets/*.js"]
```

`harness.desktop` 包不存在于 `src/` 中。会导致 setuptools 告警或构建失败。

---

### 14. 内存提取器只支持中文关键词

**文件：** `memory/extractors.py:8-19`

正则表达式只匹配中文模式（"我喜欢"、"我们决定"、"以后遇到这种情况"、"这个项目"）。用户用英文表达偏好或决策时不会被捕获。

---

### 15. README.md 缺失

`pyproject.toml` 指定 `readme = "README.md"`，但根目录下没有该文件。会导致 pip 安装时的包元数据不完整。

---

### 16. 懒加载 ImportError 被静默吞掉

**文件：** `cli/main.py:103-107`

```python
try:
    from harness.cli.legacy import register_legacy_commands
    register_legacy_commands(app)
except ImportError:
    pass
```

如果 `legacy.py` 的依赖链中有其他 ImportError（例如第三方库缺失），会被静默忽略，用户不会收到任何反馈。

---

## 四、跨层架构问题

### 17. Intent 路由未在新 Agent 中使用

旧 Orchestrator 有完整的意图路由（`intent/router.py`）——检测用户意图是"出题"、"复习"、"做闪卡"还是"研究网站"。新 Agent 系统完全依赖 LLM 自行决定调用什么工具，没有结构化的路由层。

这意味着：
- 学习工具（generate_quiz、generate_flashcards 等）注册为 Agent 工具，但工具本身只是生成 prompt 返回，并不调用 LLM
- Agent 需要额外调用 LLM 来处理这些工具的返回值，增加了 token 消耗和延迟

### 18. 技能系统与新 Agent 未集成

`skills/runner.py`（技能运行器）依赖废弃的 `LocalModelRuntime`，与新的 `Agent` 系统完全独立。`laicai chat` 中无法使用 `skill exec` 功能。

---

## 五、改进建议优先级

| 优先级 | 建议 | 影响 |
|---|---|---|
| 🔴 P0 | 安全加固 sandbox | 高 |
| 🔴 P0 | 增加核心模块测试 | 高 |
| 🟠 P1 | 统一两套 LLM 后端 | 高 |
| 🟠 P1 | 统一两套会话存储 | 中 |
| 🟠 P1 | 修复 save_session 的事务安全 | 中 |
| 🟡 P2 | 清理死代码 (ContextAssembler) | 低 |
| 🟡 P2 | 添加 README.md | 低 |
| 🟡 P2 | 修复 pyproject.toml package-data | 低 |
| 🟡 P2 | 内存提取器添加英文模式 | 中 |
| 🟢 P3 | VaultIndex 性能优化 | 中 |
| 🟢 P3 | 文件名添加 UUID 防冲突 | 低 |
| 🟢 P3 | Intent 路由与新 Agent 打通 | 低 |
| 🟢 P3 | 技能系统 Agent 集成 | 低 |

---

*本报告基于 2026-05-01 的完整源码审查生成。所有问题分类基于代码静态分析，未运行集成测试。*
