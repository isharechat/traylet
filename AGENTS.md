# Traylet 开发指引

## 项目范围

首个 MVP 是 macOS 菜单栏截图编辑、输入/截图翻译和始终本机保存、整段运行记录的剪贴板历史。权威范围见[首个 MVP](docs/product/mvp.md)，文档入口见[docs/README.md](docs/README.md)。先检查当前源码和任务状态；不要根据历史归档推断当前实现或验收结果。

## 开始任务

- 新增产品行为前读 MVP 说明、产品地图和对应[模块文档](docs/development/modules/README.md)。改采集、持久化、权限或外发时必读[数据与隐私](docs/development/privacy.md)。
- UI 改动遵循[设计约束](docs/development/design.md)。版本、包、签名或安装操作遵循[Beta 打包](docs/development/packaging.md)与[验收清单](docs/development/acceptance.md)。
- 规格、源码行为、合成/系统验证分别陈述。测试结果按通过、跳过、排除、失败分类。

## 权限与数据

- 屏幕采集、辅助功能和语言资源使用 macOS 正常流程；不改 TCC、Gatekeeper、系统信任或绕过授权。
- 剪贴板整段运行始终记录，从启动后的新 change-count 基线开始，不补录启动前内容；普通历史与收藏始终写入 `~/Library/Application Support/Traylet/v2/clipboard` 的未加密归档。无逐次确认，也无运行时开启/关闭或暂停开关，仅退出时停止。外部服务须明确目标、内容和发送动作。
- V2 用户数据保留在新版命名空间；不读取、迁移或删除旧版资料。未加载正文不得以空状态覆盖归档。
- 本机可逆构建与测试可自主完成；不得把合成证据说成系统集成验收。

## 代码与并行

- 主线拥有 Application、Capture、Shared、Evidence、工程和脚本；Editing、Translation、Clipboard、Settings、Localization 按对应模块所有权修改。
- 修改共享接口前核对所有调用方与测试；并行工作不得覆盖共享文件。
- 当前菜单入口固定为区域/屏幕截图、输入/截图翻译、剪贴板、设置、退出。滚动截图仍未完成，不接入产品菜单或把红测算作通过。

## 构建、验证与版本

从根目录使用：

```sh
scripts/swift-local.sh build
scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests
python3 -m unittest discover -s Tests/TrayletToolingTests
```

当前修正版 Beta 目标为 `0.1.0-beta.2` / build `3`：`VERSION` 与 `BUILD_NUMBER` 是打包元数据源。Beta 1 因签名封装错误已撤回，该缺陷已修复。

应用组装与签名统一走 `scripts/assemble-app.sh`：`build-from-source.sh`（开源用户，无需证书）、`package-local.sh` 和 `package-ci.sh` 都调用它。新增打包入口或改动资源时不得绕过它单独签名二进制，否则会重现"已损坏"提示。

打包产物在上传前必须通过 `scripts/smoke-package.sh`（解包、严格验签、核对版本、实际启动打包后的二进制）。验签通过不等于能运行，这条检查不得省略。

发布有两条通道，tag 决定通道：与 `VERSION` 完全相同的 tag 是正式通道，必须 Developer ID 签名并完成 Apple 公证，缺凭据即失败关闭；加 `-preview` 后缀的 tag 是预览通道，产出 ad-hoc 签名的未公证包，Release 说明须标注该边界。两条通道的详细要求见[Beta 打包](docs/development/packaging.md)。

不能把打包等同放行；安装用 `scripts/deliver-local.sh`，其运行状态未知时会安全暂存且不强退。打包和验收状态只更新到[验证记录](docs/development/verification.md)。

## 文档

产品与工程文档以 `docs/` 当前主线为准；`docs/archive/` 是只读历史记录。用户要求改本文件时，按 writing-for-agents skill 写作并同步更新对应文档入口。遇到已证实的重复缺陷，记录复现条件、修复点和验证边界到 known-errors。

原型浏览器访问限制见[当前约束](docs/development/browser-access.md)；已有明确拒绝，不用其他路线绕过。
