# 贡献指南

感谢你愿意参与来财。这个项目目前以 macOS 原生应用和本地 Agent 工具链为主，优先欢迎能提升稳定性、交互流畅度、任务成功率和代码可维护性的改动。

## 本地准备

需要 macOS 14、Xcode 15 或更新版本，以及 Swift 5.9 或更新版本。

```bash
bash scripts/check_macos_toolchain.sh
swift test --package-path native-macos
```

## 常用命令

```bash
bash scripts/check_project_hygiene.sh
bash scripts/check_swift_file_sizes.sh
swift test --package-path native-macos
LAICAI_ARCHS=arm64 bash native-macos/build.sh
LAICAI_ARCHS=arm64 bash native-macos/package_dmg.sh
```

`native-macos/dist/` 是本地构建产物目录，默认不提交到仓库。

`bash scripts/lint_swift.sh` 可用于风格债清理；当前仓库仍有存量 lint 问题，不作为普通贡献的默认阻塞项。

## 提交前检查

- 不提交 API Key、OAuth Token、Cookie、个人路径或运行时数据。
- 保持变更聚焦，一次 PR 尽量解决一个问题。
- 大改动请补充测试；修复交互问题时，尽量补充能覆盖状态流转的回归测试。
- 提交时显式 stage 要提交的文件，例如：`git add -- README.md native-macos/package_dmg.sh`。

## 代码风格

- 优先沿用现有 SwiftUI、AppStore action 和 Foundation engine 的拆分方式。
- 小修小补不要引入新抽象；共享逻辑确实重复或影响任务可靠性时再抽取。
- 用户可见文案保持简短、明确，不把内部实现细节暴露给普通用户。
