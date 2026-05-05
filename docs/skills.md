## 安全审查（安装前强制）

**规则**：安装任何外部 skill 前，必须先走安全审查流程。禁止直接照搬安装。

审查使用内置 `skill-review` skill：

```bash
laicai skill exec skill-review --goal "审查 https://example.com/skill 这个 skill" --url https://example.com/skill
```

审查五步：
1. **来源审查** — 检查来源是否可信（仓库/网页/文件/粘贴）
2. **权限审查** — 检查是否会读文件、写 Obsidian、联网、执行命令
3. **逻辑审查** — 判断核心目标是否合理、有无过度复杂或隐藏行为
4. **改写判断** — 默认不照搬，提炼核心思路改写为来财自有 skill
5. **用户确认** — 审查报告输出后必须等用户确认才能安装

改写原则：
- 只保留必要能力，删除危险能力
- prompt、配置、文件结构按来财规范重写
- 任何包含 shell 命令或文件写入的 skill 默认标记为高风险

---

Skills are plain folders under `skills/`.

Each skill contains:

- `skill.json`
- `prompt.md`

## Create one

```bash
laicai skill new daily-brief --description "Summarize recent notes and web findings into a short daily brief."
```

## Create from natural language

```bash
laicai skill create --request "做一个 skill，先查知识库里的项目笔记，再抓网页，然后整理成可保存到 Obsidian 的研究笔记"
```

You can also pin the folder name:

```bash
laicai skill create --name repo-brief --request "做一个 skill，用来把项目相关笔记整理成简短日报并默认保存"
```

## Execute one

```bash
laicai skill exec website-research --goal "总结 OpenAI 首页重点" --url https://openai.com --save
```

## Inspect one

```bash
laicai skill show website-research
```

## Edit one

Open the generated folder and adjust:

- step order in `skill.json`
- tool list in `skill.json`
- behavior and output format in `prompt.md`

## Manifest shape

```json
{
  "name": "daily-brief",
  "description": "Summarize recent notes and web findings into a short daily brief.",
  "tools": ["web.fetch", "vault.capture"],
  "steps": [
    {
      "kind": "vault_context",
      "name": "vault-context",
      "query_from": "goal",
      "limit": 4
    },
    {
      "kind": "prompt",
      "name": "prompt"
    },
    {
      "kind": "save_note",
      "name": "save-note",
      "folder": "02 Notes",
      "save_by_default": false
    }
  ],
  "vault_context": {
    "enabled": true,
    "query_from": "goal",
    "limit": 4
  },
  "web_fetch": {
    "enabled": false,
    "url_from": "manual"
  },
  "output": {
    "save_by_default": false,
    "folder": "02 Notes",
    "title_template": "{{skill}} - {{goal}}"
  }
}
```

## Step kinds

- `vault_context`: search the vault and inject note previews into the prompt
- `web_fetch`: fetch a URL and inject the cleaned page text
- `prompt`: call the local model with the rendered prompt
- `save_note`: write the final output back into the vault

If `steps` is omitted, 来财 will build a simple default flow from `vault_context`, `web_fetch`, and `output`.

## Prompt template

Use these placeholders:

- `{{goal}}`
- `{{extra_context}}`
- `{{fetched_url}}`
- `{{fetched_text}}`

## Suggested first custom skills

- `pdf-to-note`
- `repo-research`
- `meeting-brief`
- `project-memory-update`
