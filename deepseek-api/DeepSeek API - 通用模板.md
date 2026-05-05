# DeepSeek API – 通用请求脚本模板

> 生成自 `deepseek-web-to-api` 技能。请按注释填入实际 URL 与认证信息。

```python
#!/usr/bin/env python3
"""模拟浏览器向 DeepSeek Web 发送聊天请求并打印回复。"""

import requests
import json

# ── 请根据浏览器的实际请求填写以下配置 ──────────────────────────
DEEPSEEK_CHAT_URL = "https://chat.deepseek.com/api/v0/chat/completions"  # 示例接口
COOKIE = ""               # 从浏览器开发者工具 → Network → 请求头中复制 Cookie
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

# ── 构造请求 ──────────────────────────────────────────────────
headers = {
    "User-Agent": USER_AGENT,
    "Cookie": COOKIE,
    "Content-Type": "application/json",
    "Accept": "application/json",
}

payload = {
    "messages": [
        {"role": "user", "content": "你好，请介绍一下你自己。"}
    ],
    "model": "deepseek-chat",
    "stream": False,
}

try:
    resp = requests.post(DEEPSEEK_CHAT_URL, json=payload, headers=headers, timeout=30)
    resp.raise_for_status()
    data = resp.json()
    # 提取助手回复（具体字段视接口返回结构调整）
    assistant_reply = data.get("choices", [{}])[0].get("message", {}).get("content", "无回复")
    print("DeepSeek 回复：", assistant_reply)
except requests.exceptions.RequestException as e:
    print(f"请求失败：{e}")
except Exception as e:
    print(f"处理异常：{e}")
```

## 使用说明

1. 在浏览器中打开 DeepSeek 聊天页面，按 F12 打开开发者工具。
2. 切换到 Network 标签，随意发送一条消息，找到 `chat/completions` 请求。
3. 右键该请求 → Copy → Copy as cURL，然后从 cURL 命令中提取 `Cookie` 和实际接口地址。
4. 将以上信息填入脚本，保存后运行：
   ```bash
   python3 deepseek_api.py
   ```
5. 如页面需登录才能访问，请确保 Cookie 有效且未过期。
