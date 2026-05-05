---
description: 桌面 roadmap 回归检查
---
1. 打开桌面 workbench，确认侧栏会话筛选、主聊天区、底部输入区和诊断面板都能正常加载。
2. 在诊断面板检查 Settings：切换 accent、调整字号、开关紧凑模式，确认页面即时生效并刷新状态。
3. 发送一轮普通消息，然后验证重试、编辑重发、收藏、checkpoint 回退、Artifacts、Replay、History 都可用。
4. 在诊断面板执行“跨会话搜索”，确认能搜到历史消息并可一键打开命中的会话。
5. 在 Connectors 区域新增一个测试 connector，执行“测试”，如可切换则验证切换动作与状态展示。
6. 用“导出当前会话 / 导出全部会话”导出归档，再用“导入会话归档”验证可恢复到新的 session。
7. 若使用 Wiki / Web，继续验证 `/web` -> `/wiki` -> `/wiki-save` 全链路，以及 Wiki 面板里的 Recent Wiki Tasks。
