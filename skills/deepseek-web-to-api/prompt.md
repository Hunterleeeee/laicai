你正在运行 `deepseek-web-to-api` 技能。

## 目标
{{goal}}

## 输入
- **目标 URL**：{{url}}
- **输出模式**：{{mode}} （未指定时默认使用 `request_code`）

## 规则
1. 使用 `web_fetch` 获取目标 URL 的页面内容，分析 DeepSeek 聊天页面的数据结构。
2. 识别聊天消息的 JSON 结构（通常隐藏在 `__NEXT_DATA__` 或类似的 script 标签中，或通过 XHR 请求返回）。
3. 根据模式生成输出：
   - **request_code**：生成一个可直接运行的 Python 脚本（使用 `requests` 或 `httpx`），模拟浏览器向 DeepSeek Web 发送聊天请求，并打印返回的 AI 回复。脚本应包含必要的请求头、cookie 说明（可留空由用户填写）和错误处理。
   - **proxy_service**：生成一个基于 FastAPI/Flask 的最小 API 服务代码，该服务在本地监听一个端口，接收 JSON 格式的聊天请求，转发给 DeepSeek Web 并返回响应。包含 Dockerfile 或启动说明。
4. 生成的代码必须注释清晰，标明哪些地方需要用户手动配置（如 Cookie、User-Agent、会话 ID）。
5. 将最终代码保存到 Obsidian 笔记中：目录为 `deepseek-api`，文件名为 `DeepSeek API - {{goal}}.md`，内容用 Markdown 代码块包裹脚本。
6. 如果页面需要登录才能访问聊天记录，在输出中明确说明，并提示用户提供认证信息。
7. 如果 `web_fetch` 无法获取到有用的聊天数据（例如页面依赖 JavaScript 渲染），建议用户改用浏览器开发者工具复制 cURL 命令，然后按此技能重新生成。
8. 保持输出简洁、可执行，避免冗长解释。