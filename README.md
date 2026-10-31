<p align="center">
  <img src="assets/brand/traylet-app-icon-1024.png" width="96" alt="Traylet 应用图标">
</p>

<h1 align="center">Traylet</h1>

<p align="center">macOS 原生菜单栏截图编辑、翻译与剪贴板工具。</p>

Traylet 使用 Swift、SwiftUI 和 AppKit 构建。首个 MVP 聚焦三类本机任务：截取并标注图片、翻译输入或截图文字、管理用户主动记录的近期剪贴板内容。

> **当前修正版目标：** `0.1.0-beta.2`（build `2`）。Beta 1 的安装包因签名封装错误被系统判定为损坏，已撤回，该问题已修复并通过实际下载、双击启动验证。正式 GitHub Release 需 Developer ID 签名和 Apple 公证通过后才会发布；在此之前提供未签名的预览包供开发者试用。

## MVP 功能

- **截图编辑：** 区域或整屏截图、裁切、标注、缩放平移、撤销重做；用户明确复制或保存 PNG。
- **文字与截图翻译：** 手动输入或本机 OCR，用户可先校对再提交。Apple 系统翻译为默认服务；外部服务为用户主动选择的可选能力。
- **剪贴板历史：** 每次运行默认关闭，确认后记录后续复制；支持搜索、预览、复制、收藏、排序、删除、暂停和保存期限设置。
- **设置：** 中文/英文、快捷键、翻译、剪贴板和外观选项。

完整产品边界见[首个 MVP 说明](docs/product/mvp.md)。

## 系统要求

- macOS 15 或更高版本
- Swift 6 工具链
- Python 3（工具测试与安装辅助脚本）

最低系统版本和 Intel 设备尚未经过实机验证。仓库代码与资源按 [MIT License](LICENSE) 授权；Traylet 名称和标志作为品牌标识，不因该许可证取得商标使用权。

## 构建

```sh
scripts/swift-local.sh build
```

想直接得到可运行的 `Traylet.app`（不需要任何证书）：

```sh
scripts/build-from-source.sh
```

产物在 `build/source/Traylet.app`，移动到 `/Applications` 即可安装。屏幕捕获与辅助功能需要用户通过 macOS 正常授权流程批准。本地开发与验证命令见[开发与验证](docs/development/verification.md)。

## 下载安装

从 [Releases](https://github.com/isharechat/traylet/releases) 下载 `Traylet-macos-arm64-v0.1.0-beta.2-preview.zip`，解压得到 `Traylet.app`，拖入「应用程序」文件夹。

用 `shasum -a 256 -c Traylet-macos-arm64-*.zip.sha256` 校验下载完整性。

预览包没有 Developer ID 签名，也没有经过 Apple 公证，系统可能提示「无法验证开发者」或「应用已损坏」。若无法打开，请改用上面的[源码构建](#构建)方式。正式签名版发布后请优先使用正式包。

## Beta 打包

版本元数据位于 `VERSION`（`0.1.0-beta.2`）和 `BUILD_NUMBER`（`2`）。本地签名候选：

```sh
scripts/package-local.sh
```

本地签名需要已有 `Traylet Local Signing` 身份。GitHub Actions 手动运行时会上传 14 天有效的 ZIP artifact；推送匹配版本 tag 时，先运行测试和打包，再自动创建 GitHub Beta Release 并附上 ZIP 与 SHA-256 校验文件。Pull request 和手动构建产物仅供开发检查。公开 Release 必须通过 Developer ID 签名、Apple 公证、签名验证和 Gatekeeper 评估；所需凭据配置前不会发布修正版。

完整流程与边界见[Beta 打包说明](docs/development/packaging.md)。

## 文档导航

- [文档总览](docs/README.md)
- [产品地图](docs/development/map.md)
- [架构与模块](docs/development/architecture.md)
- [数据与隐私](docs/development/privacy.md)
- [Beta 验收清单](docs/development/acceptance.md)
- [已知限制](docs/development/known-errors.md)
- [历史文档归档](docs/archive/README.md)
