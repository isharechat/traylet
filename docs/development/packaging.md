# 首个 Beta 打包

## 版本标识

- 产品版本：`0.1.0-beta.1`
- `VERSION`：`0.1.0-beta.1`
- `BUILD_NUMBER`：`1`
- macOS `CFBundleShortVersionString`：`0.1.0`
- macOS `CFBundleVersion`：`1`
- 自定义 `TrayletReleaseVersion`：`0.1.0-beta.1`
- Bundle ID：`local.traylet.app`

版本文本和构建号分别用于预发布标识与 Apple bundle 数值版本。每次新的 Beta 构建递增 build；产品版本变化时同步更新 `VERSION` 和对应 Git tag。关于页显示完整的 `0.1.0-beta.1 (构建 1)`。

## 本地签名候选

```sh
scripts/package-local.sh
```

脚本使用 `Traylet Local Signing` 身份并进行严格签名检查。身份缺失时停止，不改用 ad-hoc、不创建证书、不修改信任设置。候选输出在 `build/`；生成候选本身不代表通过测试、安装或发行验收。

完整本地交付入口 `scripts/deliver-local.sh` 会先运行本地验证并交给受保护的安装器。运行状态未知时暂存；不会强退应用或修改 TCC/Gatekeeper。首个 Beta 的首轮准备不调用该安装流程。

## GitHub Actions

`.github/workflows/macos-package.yml` 在 macOS 26 runner 上运行 Swift 和 Python 测试，以匹配工程使用的 macOS 26 SDK。手动触发会上传保留 14 天的未签名 ZIP artifact。推送与 `VERSION` 完全匹配的 `v0.1.0-beta.1` tag 时，测试与打包成功后会自动创建 GitHub prerelease，并将 ZIP 与 SHA-256 文件作为 Release 资产上传。CI 使用提交在 `BUILD_NUMBER` 中的构建号，GitHub run number 只用于区分工作流产物。

CI 包含 SwiftPM release 二进制、app 图标、资源 bundle、版本 plist 和 `THIRD_PARTY_NOTICES.md`。CI 不签名、不公证、不安装或启动应用。Release 只在通过 tag 触发且测试/打包成功后创建；工作流会拒绝覆盖同 tag 的已有 Release。未签名包可能显示 Gatekeeper 提示。

## Beta 限制

项目源码使用仓库根目录的 MIT License。公开分发仍需单独完成开发者身份签名、公证、隐私文案和发布流程。不得把内部签名、ZIP 完整性或 CI 绿色结果描述为已获 Apple 公证或用户系统权限。
