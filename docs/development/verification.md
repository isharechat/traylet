# 验证记录

## 当前版本与验证状态

- **当前目标版本**：`0.1.0-beta.1` / build `1`（`VERSION` 与 `BUILD_NUMBER`）。
- **本机构建与测试**（目录结构重整后，Apple Silicon，Swift 测试在沙箱外执行以便 SwiftPM 写入 `.build`）：
  - `scripts/dev/swift-local.sh build`：退出码 `0`，Build complete。
  - `scripts/dev/swift-local.sh test --no-parallel --skip EditingColorWellTests`：退出码 `0`。共 407 个测试、81 个 suite；**387 个通过、20 个跳过**（环境条件未设置，如离屏快照目录未指定或无 AX 树）、**0 个失败**；`EditingColorWellTests` 按命令显式排除。
  - `python3 -m unittest discover -s Tests/TrayletToolingTests`：退出码 `0`，**41 个测试全部通过**。
- **尚未完成的系统与发布验收**：
  - Developer ID 签名与 Apple 公证（当前工作区无 Developer ID 证书；公开正式通道需配置相应 GitHub Actions secrets）。
  - 真实前台多应用焦点、物理键盘/IME、VoiceOver、多显示器、真实 macOS 15 最低版本及 Intel 设备实机验收（详见[发布验收清单](acceptance.md)）。

## 标准验证命令

```sh
scripts/dev/swift-local.sh build
scripts/dev/swift-local.sh test --no-parallel --skip EditingColorWellTests
python3 -m unittest discover -s Tests/TrayletToolingTests
scripts/package/build-from-source.sh
scripts/package/smoke-package.sh <archive.zip>
scripts/package/package-local.sh
```

发布候选还需同包取证和 `scripts/install/deliver-local.sh` 所要求的证据检查；打包或单测通过本身不构成系统验收或发布放行。

## 结果口径与证据分级

- 测试结果须明确按**通过、跳过、排除、失败**分别陈述；不得将因条件跳过（如空 AX 树或未设置快照目录）或显式排除的测试算作通过。
- 记录每次命令退出码、SDK/OS 与日志路径；测试失败与环境阻塞分开描述。
- 原生合成离屏图（`--v2-native-evidence`）只证明指定原生组件布局与合成断言，不证明真实前台视觉、WindowServer 材质、物理输入、系统权限或外部服务质量。
- 直接执行与 LaunchServices 启动的权限状态分开记录。

## 历史里程碑验证摘要

以下里程碑已在各自实现轮次完成对应定向单测、离屏合成验证或打包冒烟，详细过程与早期日志见维护者本地历史归档：

1. **资源封印修复与冒烟流程（Beta 2 起）**：统一由 `scripts/package/assemble-app.sh` 先写完 `Info.plist` 与资源再整体签名；新增 `scripts/package/smoke-package.sh` 在上传产物前解包、严格验签、核对版本并以 `--v2-native-evidence` 实际启动二进制；`Tests/TrayletToolingTests/test_app_assembly.py` 覆盖回归。
2. **剪贴板整段运行与详情展开**：启动时建立新 `changeCount` 基线，整段运行持续记录并写入 `~/Library/Application Support/Traylet/v2/clipboard` 未加密归档；列表默认不选中，详情面板预构建并在选中后动画展开；空闲轮询优化经 `ReferencePerformanceTests` 合成基线验证。
3. **翻译系统语言包、短文本回退与分层选区读取**：支持设置页检查/触发系统语言包下载及缺失跳转；`TranslationLanguageDetector.detectOrInfer` 对短文本做书写系统保守回退；输入翻译快捷键采用三级 AX 查询 + 有界遍历 + 浏览器 AppleScript/菜单 Copy/模拟 `⌘C` 分层策略链；引擎图标切换直接发送并保留首次按钮发送确认。
4. **开源自动更新与目录规范化**：内置基于 GitHub Releases API 与 `.zip.sha256` + `codesign` 校验的更新器；源码与测试目录完成扁平化并统一移除类型与文件中的 `V2` 前缀。
