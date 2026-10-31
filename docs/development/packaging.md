# 首个 Beta 打包

## 版本标识

- 产品版本：`0.1.0-beta.2`
- `VERSION`：`0.1.0-beta.2`
- `BUILD_NUMBER`：`2`
- macOS `CFBundleShortVersionString`：`0.1.0`
- macOS `CFBundleVersion`：`2`
- 自定义 `TrayletReleaseVersion`：`0.1.0-beta.2`
- Bundle ID：`local.traylet.app`

版本文本和构建号分别用于预发布标识与 Apple bundle 数值版本。每次新的 Beta 构建递增 build；产品版本变化时同步更新 `VERSION` 和对应 Git tag。关于页显示完整的 `0.1.0-beta.2 (构建 2)`。

## 本地签名候选

```sh
scripts/package-local.sh
```

脚本使用 `Traylet Local Signing` 身份并进行严格签名检查。身份缺失时停止，不改用 ad-hoc、不创建证书、不修改信任设置。候选输出在 `build/`；生成候选本身不代表通过测试、安装或发行验收。

完整本地交付入口 `scripts/deliver-local.sh` 会先运行本地验证并交给受保护的安装器。运行状态未知时暂存；不会强退应用或修改 TCC/Gatekeeper。修正版 Beta 发布前不调用该安装流程。

## 公开发行凭据

GitHub 仓库所有者需准备 Apple Developer ID Application 证书并导出含私钥的 `.p12`，再创建用于公证的 App Store Connect API key。Apple 账号材料和私钥不得提交到源码仓库；只将以下值保存为 GitHub Actions repository secrets：

- `MACOS_DEVELOPER_ID_P12_BASE64`：`.p12` 文件的 Base64 内容。
- `MACOS_DEVELOPER_ID_P12_PASSWORD`：导出 `.p12` 时设置的密码。
- `APPLE_TEAM_ID`：Developer ID 所属团队标识。
- `APPSTORE_CONNECT_KEY_ID`、`APPSTORE_CONNECT_ISSUER_ID`：公证 API key 标识。
- `APPSTORE_CONNECT_PRIVATE_KEY_P8`：对应 `.p8` 私钥全文。

Developer ID 证书和 App Store Connect key 的创建方式见 [Apple Developer ID 说明](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) 与 [Apple 公证命令行说明](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。设置好 secrets 后，再推送与 `VERSION` 相同的版本 tag。工作流缺少任何值、签名、提交公证、staple 或 Gatekeeper 验证失败时都会停止，不创建 Release。

## GitHub Actions

`.github/workflows/macos-package.yml` 在 GitHub 托管的 Xcode 27 arm64 runner（公开预览）上运行 Swift 和 Python 测试，以匹配工程使用的 macOS 26 SDK，并避开 Xcode 26.6 / Swift 6.3.3 的已知编译器崩溃。手动触发会上传保留 14 天的 ad-hoc 签名检查包，不能作为公开发行。推送与 `VERSION` 完全匹配的 `v0.1.0-beta.2` tag 时，工作流要求以下 GitHub Actions secrets：`MACOS_DEVELOPER_ID_P12_BASE64`、`MACOS_DEVELOPER_ID_P12_PASSWORD`、`APPLE_TEAM_ID`、`APPSTORE_CONNECT_KEY_ID`、`APPSTORE_CONNECT_ISSUER_ID`、`APPSTORE_CONNECT_PRIVATE_KEY_P8`。通过签名、公证、票据固定、严格验签和 Gatekeeper 评估后才创建 GitHub prerelease；凭据缺失时 tag 工作流会失败关闭。CI 使用提交在 `BUILD_NUMBER` 中的构建号，GitHub run number 只用于区分工作流产物。

CI 包含 SwiftPM release 二进制、app 图标、资源 bundle、版本 plist 和 `THIRD_PARTY_NOTICES.md`。公开 Release 使用 Developer ID 签名并完成 Apple 公证；CI 不安装或启动应用。ad-hoc 检查包不受 Gatekeeper 信任，不能公开给普通用户安装。工作流会拒绝覆盖同 tag 的已有 Release。

## Beta 限制

项目源码使用仓库根目录的 MIT License。公开分发仍需单独完成开发者身份签名、公证、隐私文案和发布流程。不得把内部签名、ZIP 完整性或 CI 绿色结果描述为已获 Apple 公证或用户系统权限。
