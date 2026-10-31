# 验证记录

## 当前首个 Beta 准备状态

- 目标版本为 `0.1.0-beta.1` / build `1`。
- 版本元数据已在 `VERSION`、`BUILD_NUMBER`、本地包脚本、CI 包脚本和关于页读取逻辑中配置。
- `scripts/swift-local.sh build` 退出码为 0，完成时间约 28.5 秒；编译器给出两条 Command Line Tools 搜索路径不存在的 linker warning，但构建成功。
- `zsh -n` 脚本语法检查、GitHub Actions YAML 解析与 Markdown 链接目标检查通过。
- 首次 GitHub tag 工作流 `41224389083` 在 macOS 15 / Xcode 16.4 / SDK 15.5 编译阶段失败；日志显示该 SDK 没有源码所用的 macOS 26 玻璃 API，并报告旧 SDK 的 ScreenCaptureKit/AppKit Sendable 注解错误。打包与 Release job 未执行。改用 macOS 26 runner 后，工作流通过标签检查，但 Swift 6.3.3 在 `V2SettingsWorkspaceView.swift` 的 IRGen 阶段因 `SmallVector unable to grow` 崩溃，打包与 Release job 未执行。该错误与 Swift 编译器已记录的问题一致；CI 改为 GitHub 公开预览的 Xcode 27 arm64 runner。Swift 6.4 编译及 Swift 测试通过；Python 工具测试发现 3 个 manifest 测试夹具缺少 Beta 元数据文件，正在补齐后重试。
- 本轮重整了 MVP 文档，并把 Beta 版本信息接入本地/CI 包元数据、应用关于页与交付输入哈希。没有生成/签名 `0.1.0-beta.1` app 包，没有安装或启动该包，也没有运行应用测试。
- 因而首个 Beta 的实际构建、同包证据、系统权限、安装和发行状态均为**待验证**。

## 执行命令

```sh
scripts/swift-local.sh build
scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests
python3 -m unittest discover -s Tests/TrayletToolingTests
scripts/package-local.sh
```

发布候选还需同包取证和 `scripts/deliver-local.sh` 所要求的证据检查。打包单独通过不能放行。

## 结果口径

记录测试总数以及通过、跳过、排除、失败；不要把空 AX 树跳过或被排除的系统 UI 测试列为通过。记录每次命令退出码、SDK/OS、源码/包哈希和日志路径。测试失败与环境阻塞（例如缺少系统资源或授权）分开描述。

原生合成图只证明生成它们的组件/输入和断言，不证明真实前台视觉、WindowServer 材质、物理键盘、权限或外部服务。直接执行和 LaunchServices 启动的权限状态分开记录。

## 既有证据

`0.3.10 / build 26` 的体验交付记录属于重整前的历史版本，留在维护者本机档案中，不纳入公开仓库。该记录不能认证 `0.1.0-beta.1`，也不能填入本版本的验收清单。
