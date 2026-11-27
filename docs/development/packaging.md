# 构建、打包与发布

## 版本标识

- 产品版本：`0.1.0-beta.1`
- `VERSION`：`0.1.0-beta.1`
- `BUILD_NUMBER`：`1`
- macOS `CFBundleShortVersionString`：`0.1.0`
- macOS `CFBundleVersion`：`1`
- 自定义 `TrayletReleaseVersion`：`0.1.0-beta.1`
- Bundle ID：`local.traylet.app`

`VERSION` 与 `BUILD_NUMBER` 是打包元数据源。每次新的 Beta 构建递增 build；产品版本变化时同步更新 `VERSION` 和对应 Git tag。关于页显示完整的 `0.1.0-beta.1 (构建 1)`。

## 从源码构建（无需证书）

```sh
scripts/package/build-from-source.sh
```

开源用户与贡献者用这个入口直接从源码得到可运行的 `Traylet.app`。脚本组装 `Info.plist` 与资源后对整个 `.app` 做 ad-hoc 签名，资源封印有效，因此本机构建的应用可以正常启动，不会被判定为损坏。ad-hoc 签名不受系统安全校验信任，所以它只适用于本机构建，不作为公开下载包分发。

输出在 `build/source/Traylet.app`，把它移动到 `/Applications` 即可安装。

## 本地签名候选

```sh
scripts/package/package-local.sh
```

脚本使用 `Traylet Local Signing` 身份并进行严格签名检查。身份缺失时停止，不改用 ad-hoc、不创建证书、不修改信任设置。候选输出在 `build/`；生成候选本身不代表通过测试、安装或发行验收。

三个打包入口（`build-from-source.sh`、`package-local.sh`、`package-ci.sh`）都调用 `scripts/package/assemble-app.sh` 完成组装与签名，避免只签二进制、不签资源而产生“已损坏”提示。

`scripts/package/smoke-package.sh` 对已打包的 ZIP 做运行时冒烟检查：解包、严格验签、核对包内 `TrayletReleaseVersion` 与仓库 `VERSION` 一致，并以 `--v2-native-evidence` 实际启动打包后的二进制。CI 在上传 artifact 前执行它，避免结构正确但运行失败的包流入下载环节。

## 本地交付与安装

完整受保护的本地安装流程：

```sh
scripts/install/deliver-local.sh
```

本地安装会替换 `/Applications/Traylet.app`。脚本先验证候选与同包证据，再调用安装器。候选或运行状态未知时安全暂存；不会强退应用、清除 quarantine、修改 TCC/Gatekeeper、变更系统信任或自动降级较新版本。单独运行 `scripts/package/package-local.sh` 只会生成本机签名候选，不会安装，也不代表通过[发布验收清单](acceptance.md)。

## 公开发行凭据

GitHub 仓库所有者需准备 Apple Developer ID Application 证书并导出含私钥的 `.p12`，再创建用于公证的 App Store Connect API key。Apple 账号材料和私钥不得提交到源码仓库；只将以下值保存为 GitHub Actions repository secrets：

- `MACOS_DEVELOPER_ID_P12_BASE64`：`.p12` 文件的 Base64 内容。
- `MACOS_DEVELOPER_ID_P12_PASSWORD`：导出 `.p12` 时设置的密码。
- `APPLE_TEAM_ID`：Developer ID 所属团队标识。
- `APPSTORE_CONNECT_KEY_ID`、`APPSTORE_CONNECT_ISSUER_ID`：公证 API key 标识。
- `APPSTORE_CONNECT_PRIVATE_KEY_P8`：对应 `.p8` 私钥全文。

Developer ID 证书和 App Store Connect key 的创建方式见 [Apple Developer ID 说明](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) 与 [Apple 公证命令行说明](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。设置好 secrets 后，再推送与 `VERSION` 相同的版本 tag。工作流缺少任何值、签名、提交公证、staple 或 Gatekeeper 验证失败时都会停止，不创建 Release。

## GitHub Actions

`.github/workflows/build-and-publish.yml` 是可复用流水线，承载 macOS 构建、签名、打包、冒烟检查与 Release 发布步骤；`.github/workflows/macos-package.yml` 与 `.github/workflows/release-on-merge.yml` 是两个入口，前者覆盖 PR / 手动触发 / tag 推送，后者覆盖「合并到 main 后自动发布」。三者都运行在 GitHub 托管的 Xcode 27 arm64 runner（公开预览）上，以匹配工程使用的 macOS 26 SDK，并避开 Xcode 26.6 / Swift 6.3.3 的已知编译器崩溃。

- **PR / 手动触发**：直接构建并打包，上传保留 14 天的 ad-hoc 签名检查包（仅供开发检查），不发布。
- **tag 推送**：推送与 `VERSION` 完全匹配的 `v0.1.0-beta.1` tag 时走正式通道，要求完整 Developer ID 与公证 secrets，通过签名、公证、票据固定、严格验签和 Gatekeeper 评估后才创建 GitHub prerelease；凭据缺失时工作流失败关闭。推送 `v0.1.0-beta.1-preview` tag 则走预览通道，跳过签名与公证。
- **合并到 main**：`release-on-merge.yml` 使用 `pull_request_target` 在 PR 合并后递增 `VERSION` 的 beta 序号与 `BUILD_NUMBER`，将递增提交回 `main` 并推送对应版本 tag，再调用可复用流水线构建与发布。该工作流只检出一致的 `refs/heads/main`、只读取合并状态，从不运行 PR 内的未审代码。配置了完整 Developer ID 凭据时发布正式签名版；未配置时自动回退为预览版（ad-hoc 签名、未公证）。

CI 使用提交在 `BUILD_NUMBER` 中的构建号，GitHub run number 只用于区分工作流产物。

## 发布通道

tag 决定发布通道，两条通道都跑完整的测试、打包、冒烟测试和 SHA-256 校验：

- `v0.1.0-beta.1`：正式通道。必须通过 Developer ID 签名与 Apple 公证，缺少任一凭据时工作流失败关闭，不产生 Release。
- `v0.1.0-beta.1-preview`：预览通道。跳过签名与公证，产出 ad-hoc 签名的预览包，Release 说明会明确写出它未签名、未公证，系统可能提示无法验证。仅供愿意自行排查的开发者和贡献者。

预览通道不是正式分发的替代品。等 Developer ID 凭据配置好后，用正式 tag 重新发布同一版本号，用户拿到的才是可正常双击安装的包。

CI 包含 SwiftPM release 二进制、app 图标、资源 bundle、版本 plist 和 `THIRD_PARTY_NOTICES.md`。公开 Release 使用 Developer ID 签名并完成 Apple 公证；CI 不安装或启动应用。ad-hoc 检查包不受 Gatekeeper 信任，不能公开给普通用户安装。工作流会拒绝覆盖同 tag 的已有 Release。

## 开源零成本分发与自动更新

在不配置 Apple Developer ID 证书的情况下，项目按零成本开源模式分发：

1. **本地源码构建**：贡献者与用户运行 `scripts/package/build-from-source.sh`，产物经 ad-hoc 签名并封印资源，本机可直接启动。
2. **GitHub Releases 预览包**：通过 `-preview` tag 发布 `Traylet-macos-arm64-*.zip` 与 `.sha256` 校验文件；首次运行被 Gatekeeper 拦截时，需由用户右键「打开」或手动清除隔离属性。
3. **Homebrew Cask 模板**：`scripts/homebrew/traylet.rb` 提供自建 Tap 的参考定义。
4. **内置开源自动更新**：`scripts/package/assemble-app.sh` 在 `Info.plist` 中写入 `TrayletUpdateFeedURL`（指向 GitHub Releases API）。应用内通过 `CryptoKit` SHA-256 校验与 `codesign --verify` 验证更新包，仅在可执行目录可写时执行替换并重启，不绕过或修改系统 Gatekeeper/TCC 状态。

## 发布限制

项目源码使用仓库根目录的 MIT License。公开分发仍需单独完成开发者身份签名、公证、隐私文案和发布流程。不得把内部签名、ZIP 完整性或 CI 绿色结果描述为已获 Apple 公证或用户系统权限。
