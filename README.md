# 来财 (Laicai)

macOS 原生 AI Agent，运行在本机，拥有完整工具链。

来财以 MIT License 开源。当前版本适合本地开发、验证和自构建发布；公开发行前仍建议补充正式签名与 Apple notarization。

## 核心能力

- **多连接器**：OpenAI / Anthropic / DeepSeek / Ollama，一键切换
- **Agent Loop**：自动规划 → 工具调用 → 验证 → 修复循环
- **工具系统**：文件读写、代码搜索、Shell 执行、联网搜索、Wiki 构建、图片生成
- **知识库**：Obsidian Vault 集成 + 持久化项目记忆
- **技能 & 工作流**：可扩展的 skill/workflow 编排
- **自我进化**：失败模式学习、提示词 A/B 测试、经验沉淀

## 环境要求

- macOS 14 或更新版本
- Xcode 15 或更新版本
- Swift 5.9 或更新版本

```bash
bash scripts/check_macos_toolchain.sh
```

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

生成 DMG：

```bash
bash native-macos/package_dmg.sh
# 或只构建当前架构，适合本机快速出包：
LAICAI_ARCHS=arm64 bash native-macos/package_dmg.sh
```

`package_dmg.sh` 默认会先执行 `build.sh`，然后生成并校验：

```text
native-macos/dist/Laicai-<version>-<build>.dmg
```

如果已经有可用的 `native-macos/dist/Laicai.app` 和 `native-macos/dist/laicai`，可跳过重新构建：

```bash
LAICAI_SKIP_BUILD=1 bash native-macos/package_dmg.sh
```

SwiftPM 入口：

```bash
cd native-macos
swift run LaicaiNativeApp
swift run laicai --help
```

## 验证

```bash
bash scripts/check_project_hygiene.sh
bash scripts/check_swift_file_sizes.sh
swift test --package-path native-macos
```

`native-macos/dist/` 是本地构建产物目录，默认不会提交到仓库。

风格检查脚本也保留在仓库中：

```bash
bash scripts/lint_swift.sh
```

当前 SwiftLint/format 仍有存量问题，适合作为后续代码精简和风格债清理入口。

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

## 开源参与

- 许可证：MIT License，见 `LICENSE`。
- 贡献方式：见 `CONTRIBUTING.md`。
- 安全问题：见 `SECURITY.md`。
