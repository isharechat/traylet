<div align="center">
  <img src="assets/brand/traylet-app-icon-1024.png" width="112" height="112" alt="Traylet" />
  <h1>Traylet</h1>
  <p><strong>轻量、本机优先的 macOS 原生菜单栏效率工具 — 截图编辑 · 划词/截图翻译 · 剪贴板历史</strong></p>

  <p>
    <a href="https://github.com/isharechat/traylet/releases"><img src="https://img.shields.io/badge/version-0.1.0--beta.1-blue" alt="Version" /></a>
    <img src="https://img.shields.io/badge/macOS-15%2B-black?logo=apple" alt="macOS 15+" />
    <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-orange" alt="Apple Silicon" />
    <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6" />
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License: MIT" /></a>
  </p>

  <p>
    <a href="#核心特性">核心特性</a> ·
    <a href="#默认快捷键">默认快捷键</a> ·
    <a href="#快速安装">快速安装</a> ·
    <a href="#隐私与系统权限">隐私与系统权限</a> ·
    <a href="#文档导航">文档导航</a> ·
    <a href="#开发与贡献">开发与贡献</a>
  </p>
</div>

---

Traylet 是一个基于 Swift 6、SwiftUI 与 AppKit 构建的纯原生 macOS 菜单栏应用，无第三方 Swift 包依赖。它围绕日常高频的三项小任务设计，强调本机离线优先与明确的用户边界：

- **无需账号或云同步**：截图、OCR、默认翻译与剪贴板归档均在本机完成。
- **原生体验**：遵循 macOS Liquid Glass 材质偏好、深浅色外观与系统权限流程，提供中英文界面。
- **开源可验证**：内置基于 GitHub Releases API 与 SHA-256 校验的原生自动更新，零第三方框架。

> **当前版本状态（`0.1.0-beta.1` / build `1`）：** 正式签名版需配置 Apple Developer ID 与公证凭据后发布；在此之前，`-preview` 通道提供 ad-hoc 签名的开源预览包，或可直接使用仓库脚本从源码在本机构建。

## 核心特性

### 截图与标注编辑
- 支持 **区域截图**（`⌃⌥1`）与 **整屏截图**，以及从剪贴板历史图片发起独立窗口二次编辑。
- 选区支持拖动、八点缩放与方向键像素微调（`1px` / `Shift` `10px` / `⌘` 调宽高）；支持 `⌘2` 适配选区、`⌘0` 重置视图、空格拖动平移。
- 内置矩形、椭圆、线条、箭头、铅笔、文字、编号、高亮（35% 透明度）、高斯模糊与不透明黑色遮挡，支持对象二次编辑与撤销/重做（`⌘Z` / `⇧⌘Z`）。
- 预览与导出图层顺序一致；支持复制 PNG（`⌘C`）、保存 PNG（`⌘S`）以及 **悬浮置顶**（`⌘F`，无标题栏可调大小窗口，右键提供复制/保存/删除/关闭）。

### 文字与截图翻译
- **输入翻译（`⌃⌥T`）**：自动尝试读取当前前台应用的选中文本并预填（依赖辅助功能权限，支持无障碍选区及浏览器 AppleScript/菜单复制/模拟 `⌘C` 兜底，拒绝安全输入框）；未授权或无选区时正常打开手动输入。
- **截图翻译（`⌃⌥4`）**：框选后使用本机 **Vision** 框架进行 OCR，支持先校对修改原文再提交翻译。
- **多引擎支持**：默认 **Apple 系统翻译**（本机离线，支持设置页检查/预下载语言包及短文本语种回退）；可选配置 **AI（OpenAI 兼容接口，支持拉取模型与搜索）**、**DeepL**、**Google** 与 **MyMemory**。
- **发送确认与安全**：AI / DeepL 密钥存放在 macOS 钥匙串；通过「翻译」按钮首次向某外部引擎发送时显示目标与正文确认，输入或配置变更立即使过期结果失效。

### 剪贴板历史
- **整段运行自动记录**：应用启动时建立新的 `changeCount` 基线，仅记录启动后的新复制内容（不补录启动前内容），退出应用即停止；支持单次「忽略下一次复制」。
- **检索与操作（`⌃⌥V`）**：支持文本/链接/图片分类筛选、关键词搜索、仅看收藏；列表默认不自动选中，选中条目后以过渡动画展开详情列；支持原格式复制、纯文本复制、收藏、删除以及对图片发起编辑副本或 OCR 翻译。
- **本机归档**：历史与收藏保存于 `~/Library/Application Support/Traylet/v2/clipboard`（未加密归档，重启恢复），可在设置中配置记录类型、上限、保留期限与排除应用（Bundle ID）。

### 系统权限集中管理与开源更新
- 「设置 → 权限」集中管理 **屏幕录制**、**辅助功能** 与 **登录时启动**，并在检测到重签或升级导致既有权限失效时提供一次性引导弹窗。
- 「设置 → 关于」内置开源自动更新，仅向 `api.github.com` 发起只读检查，下载前强制校验官方 `.zip.sha256` 摘要与 Bundle ID / 代码签名，支持在可写 `/Applications` 目录一键替换重启。

## 默认快捷键

全局快捷键可在「设置 → 快捷键」中自定义录制或清除：

| 操作 | 默认快捷键 | 说明 |
| --- | --- | --- |
| 区域截图 | `⌃⌥1` | 框选屏幕区域并打开编辑器 |
| 屏幕截图 | 未设置 | 截取整屏（可在设置中绑定） |
| 输入翻译 | `⌃⌥T` | 打开翻译窗口（尝试预填前台选中文本） |
| 截图翻译 | `⌃⌥4` | 框选区域进行本机 OCR 与翻译 |
| 剪贴板历史 | `⌃⌥V` | 打开剪贴板历史窗口 |
| 打开设置 | `⌘,` | 菜单栏内打开设置窗口 |
| 退出应用 | `⌘Q` | 退出 Traylet 并停止剪贴板记录 |

## 快速安装

### 系统要求
- macOS 15 或更高版本
- Apple Silicon (`arm64`)
- 源码构建与测试需 Swift 6 工具链与 Python 3

> 注：macOS 15 最低系统版本及 Intel 设备尚未经过实机验证。

### 方式一：从 GitHub Releases 下载

前往 [Releases](https://github.com/isharechat/traylet/releases) 下载 `Traylet-macos-arm64-*.zip` 与 `.sha256` 文件并校验完整性：

```sh
shasum -a 256 -c Traylet-macos-arm64-*.zip.sha256
```

解压后将 `Traylet.app` 拖入「应用程序」文件夹。

> **预览包首次打开提示：** 未配置 Developer ID 公证的 `-preview` 预览包采用 ad-hoc 签名，首次运行可能被 macOS Gatekeeper 拦截。请在「访达」中按住 `Control` 键右键点击 `Traylet.app` 选择「打开」，或在终端运行：
> ```sh
> xattr -cr /Applications/Traylet.app
> ```

### 方式二：从源码直接构建（推荐，无需证书）

```sh
git clone https://github.com/isharechat/traylet.git
cd traylet
scripts/package/build-from-source.sh
```

脚本会编译、组装并完成本机 ad-hoc 签名与资源封印，产物位于 `build/source/Traylet.app`，拖入 `/Applications` 即可运行。

### 方式三：Homebrew Cask 模板

仓库在 [`scripts/homebrew/traylet.rb`](scripts/homebrew/traylet.rb) 提供了 Homebrew Cask 模板，可用于自建 Tap 分发。

## 隐私与系统权限

Traylet 严格遵循 macOS 原生权限机制，不修改 TCC 记录、不绕过系统授权或 Gatekeeper：

| 权限 | 必需性 | 用途 |
| --- | --- | --- |
| **屏幕录制** | 截图必需 | 区域截图、整屏截图与截图翻译 |
| **辅助功能** | 可选 | 输入翻译快捷键读取前台应用选中文本 |
| **登录时启动** | 可选 | 登录后自动在菜单栏启动 Traylet |

- **外部请求边界**：仅在用户主动选择外部翻译引擎或开启自动更新检查时发起对应网络请求；默认系统翻译、OCR 与剪贴板归档均完全在本机运行。
- **详细说明**：请参阅[系统权限说明](docs/guide/permissions.md)与[数据与隐私](docs/development/privacy.md)。

## 文档导航

| 类别 | 文档 | 说明 |
| --- | --- | --- |
| **应用指南** | [文档中心](docs/README.md) | 全部用户指南与开发文档总入口 |
| | [快速上手](docs/guide/getting-started.md) | 安装、菜单、快捷键与设置总览 |
| | [截图与标注编辑](docs/guide/capture-and-editing.md) | 截图模式、微调操作、工具与悬浮置顶 |
| | [文字与截图翻译](docs/guide/translation.md) | 选区读取、OCR、系统语言包与外部引擎 |
| | [剪贴板历史](docs/guide/clipboard.md) | 记录生命周期、搜索筛选与本机归档 |
| | [系统权限说明](docs/guide/permissions.md) | 权限用途与重签/升级后失效引导 |
| **开发文档** | [架构与模块](docs/development/architecture.md) | 源码结构、模块边界与共享接口 |
| | [构建、打包与发布](docs/development/packaging.md) | 签名、公证、双通道 CI 与本地交付 |
| | [开发与验证](docs/development/verification.md) | 测试命令、证据分级与验证状态 |
| | [发布验收清单](docs/development/acceptance.md) | 本地回归、系统验收与放行核对项 |
| | [已知限制](docs/development/known-errors.md) | 已知限制、已确认缺陷与防复发规则 |

## 开发与贡献

### 本地构建与测试

```sh
# 1. 编译
scripts/dev/swift-local.sh build

# 2. 运行 Swift 单元测试（排除需人工/系统交互的 EditingColorWellTests）
scripts/dev/swift-local.sh test --no-parallel --skip EditingColorWellTests

# 3. 运行脚本与打包工具测试
python3 -m unittest discover -s Tests/TrayletToolingTests
```

### 本地签名候选与打包

版本元数据由根目录 `VERSION` 与 `BUILD_NUMBER` 统一管理。所有打包脚本统一调用 `scripts/package/assemble-app.sh` 完成资源写入与整体签名，并通过 `scripts/package/smoke-package.sh` 进行解包、严格验签与实际启动冒烟检查：

```sh
scripts/package/package-local.sh        # 生成本地签名候选（需 Traylet Local Signing 身份）
scripts/install/deliver-local.sh        # 本地验证并安全交付至 /Applications
```

### 发布流程（CI）

- **PR / 手动触发**：运行 Swift 与 Python 测试，生成并上传保留 14 天的构建产物。
- **tag 推送**：与 `VERSION` 一致的 `v*` tag 走 Developer ID 签名与 Apple 公证正式通道（缺凭据即失败关闭）；`v*-preview` tag 走未公证预览通道。
- **合并到 `main`**：PR 合并后由 `release-on-merge.yml` 自动递增 beta 版本号、打 tag 并触发对应通道构建发布。

贡献代码前请阅读 [AGENTS.md](AGENTS.md) 与 [架构与模块](docs/development/architecture.md)。

## 许可证

仓库源码与资源按 [MIT License](LICENSE) 授权；第三方系统框架声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。Traylet 名称和标志作为品牌标识，不因该许可证取得商标使用权。
