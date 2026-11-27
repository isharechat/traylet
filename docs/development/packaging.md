# 构建、打包与发布

## 版本元数据

根目录 `VERSION` 与 `BUILD_NUMBER` 是版本信息的唯一来源：

- Bundle ID：`local.traylet.app`
- `Info.plist` 中的 `TrayletReleaseVersion` 与 `VERSION` 保持一致；`CFBundleShortVersionString` 取三段式基础版本号，`CFBundleVersion` 取 `BUILD_NUMBER`。

## 统一组装与冒烟检查

仓库中所有打包入口均调用 `scripts/package/assemble-app.sh` 完成 `Info.plist` 生成、图标与资源 bundle 写入以及整个 `.app` 的统一签名与严格验签（避免仅签二进制而未封印资源导致系统提示“已损坏”）。

打包后的压缩包通过 `scripts/package/smoke-package.sh` 执行运行时冒烟验证：解压、`codesign --verify --deep --strict` 验签、核对包内版本号并实际启动应用二进制。

## 本地构建与交付

- **开源源码构建（无需证书）**：
  ```sh
  scripts/package/build-from-source.sh
  ```
  生成经过本机 ad-hoc 签名的 `build/source/Traylet.app`，可直接拖入 `/Applications` 运行。
- **本地签名候选与交付**：
  ```sh
  scripts/package/package-local.sh    # 使用 Traylet Local Signing 身份生成候选
  scripts/install/deliver-local.sh    # 校验候选后安全替换 /Applications/Traylet.app
  ```
- **Homebrew Cask**：参考 [`scripts/homebrew/traylet.rb`](../../scripts/homebrew/traylet.rb)。

## GitHub Actions 双通道发布

流水线定义在 `.github/workflows/build-and-publish.yml`，由 `macos-package.yml` 与 `release-on-merge.yml` 调用，运行于 Xcode 27 `arm64` runner：

- **正式通道（`v<VERSION>` tag）**：要求配置完整的 Apple Developer ID 证书与 App Store Connect API Key secrets，完成签名、Apple 公证、票据固定（staple）与 Gatekeeper 评估后发布正式 Release；缺少任一凭据即失败退出。
- **预览通道（`v<VERSION>-preview` tag）**：跳过 Developer ID 公证，产出 ad-hoc 签名的开源预览包与 `.sha256` 校验文件，并在 Release 说明中标注未公证边界。

### 正式发布所需 Repository Secrets

- `MACOS_DEVELOPER_ID_P12_BASE64` / `MACOS_DEVELOPER_ID_P12_PASSWORD`
- `APPLE_TEAM_ID`
- `APPSTORE_CONNECT_KEY_ID` / `APPSTORE_CONNECT_ISSUER_ID` / `APPSTORE_CONNECT_PRIVATE_KEY_P8`

## 内置开源自动更新

`scripts/package/assemble-app.sh` 会在 `Info.plist` 中写入 `TrayletUpdateFeedURL`。应用内通过 `CryptoKit` 强制校验 `.zip.sha256` 摘要以及新旧包的代码签名与 Bundle ID，仅在安装目录可写时执行替换并重启。
