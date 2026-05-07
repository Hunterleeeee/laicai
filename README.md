# 来财 (Laicai)

macOS 原生 AI Agent，运行在本机，拥有完整工具链。

## 核心能力

- **多连接器**：OpenAI / Anthropic / DeepSeek / Ollama，一键切换
- **Agent Loop**：自动规划 → 工具调用 → 验证 → 修复循环
- **工具系统**：文件读写、代码搜索、Shell 执行、联网搜索、Wiki 构建、图片生成
- **知识库**：Obsidian Vault 集成 + 持久化项目记忆
- **技能 & 工作流**：可扩展的 skill/workflow 编排
- **自我进化**：失败模式学习、提示词 A/B 测试、经验沉淀

## 构建安装

```bash
bash native-macos/build.sh
# 产出:
#   native-macos/dist/Laicai.app
#   native-macos/dist/laicai
#   native-macos/dist/install_laicai.command
```

`build.sh` 会从脚本位置推导仓库根目录，默认构建 macOS 14 universal binary（arm64 + x86_64）。
如需只构建当前架构，可设置：

```bash
LAICAI_ARCHS=arm64 bash native-macos/build.sh
```

SwiftPM 入口：

```bash
cd native-macos
swift run LaicaiNativeApp
swift run laicai --help
```

## 项目结构

```
native-macos/Sources/
  LaicaiNativeApp/       # 应用入口
  LaicaiNativeDomain/    # 数据模型
  LaicaiNativeFoundation/# Agent、工具、连接器、记忆
  LaicaiNativeUI/        # SwiftUI 界面
  LaicaiNativeCLI/       # CLI 工具
skills/                  # 可扩展技能定义
docs/                    # 架构文档
assets/                  # 图标资源
```
