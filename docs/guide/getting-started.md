# 快速上手

Traylet 是一款轻量、本机优先的 macOS 原生菜单栏工具，集成截图标注、输入/截图翻译与剪贴板历史。

## 系统要求

- **操作系统**：macOS 15 或更高版本
- **架构**：Apple Silicon (`arm64`)
- **源码构建额外要求**：Swift 6 工具链、Python 3（用于工具测试与辅助脚本）

> 注：macOS 15 最低系统版本及 Intel 设备尚未经过实机完整验证。

## 安装方式

### 1. 从 GitHub Releases 下载

前往 [GitHub Releases](https://github.com/isharechat/traylet/releases) 下载 `Traylet-macos-arm64-*.zip` 及对应的 `.sha256` 校验文件：

```sh
shasum -a 256 -c Traylet-macos-arm64-*.zip.sha256
```

解压后将 `Traylet.app` 拖入「应用程序（`/Applications`）」文件夹。

> **关于未公证预览包**：`*-preview` 通道的预览包采用 ad-hoc 签名且未经 Apple 公证，首次打开时 macOS Gatekeeper 可能会拦截。你可以：
> - 在「访达」中按住 `Control` 键右键点击 `Traylet.app` 选择「打开」；或
> - 在终端执行 `xattr -cr /Applications/Traylet.app` 解除下载隔离属性后再打开。

### 2. 从源码构建（无需 Apple 开发者证书）

```sh
scripts/package/build-from-source.sh
```

构建脚本会完成组装与本机 ad-hoc 签名，产物位于 `build/source/Traylet.app`，将其拖入 `/Applications` 即可直接运行。

### 3. Homebrew Cask 模板

仓库在 `scripts/homebrew/traylet.rb` 提供了 Homebrew Cask 模板，可用于自建 Tap 分发。

## 菜单栏入口

启动后，Traylet 常驻在屏幕顶部菜单栏。点击菜单栏图标可访问以下功能：

- **区域截图** / **屏幕截图**
- **输入翻译** / **截图翻译**
- **剪贴板**
- **设置**（`⌘,`）
- **退出**（`⌘Q`）

## 默认全局快捷键

所有全局快捷键均可在「设置 → 快捷键」中重新录制或清除：

| 功能 | 默认快捷键 | 说明 |
| --- | --- | --- |
| 区域截图 | `⌃⌥1` | 框选屏幕区域并进入标注编辑器 |
| 屏幕截图 | 未设置 | 截取当前屏幕并进入标注编辑器（可在设置中绑定） |
| 输入翻译 | `⌃⌥T` | 打开翻译窗口；若前台应用有选中文本则尝试自动预填 |
| 截图翻译 | `⌃⌥4` | 框选屏幕区域进行本机 OCR 识别并翻译 |
| 剪贴板 | `⌃⌥V` | 打开剪贴板历史浮窗 |

## 设置概览

按 `⌘,` 或从菜单栏进入「设置」，包含以下六个分区：

1. **通用**：应用语言（跟随系统 / 简体中文 / English）、外观（跟随系统 / 浅色 / 深色）及 Liquid Glass 材质偏好。
2. **快捷键**：全局唤醒快捷键录制、冲突检测与恢复默认。
3. **翻译**：Apple 系统翻译语言包管理、默认翻译引擎、外部服务配置（OpenAI 兼容服务、DeepL 等）以及辅助功能授权状态。
4. **剪贴板**：本机归档上限、保留期限、记录类型、排除应用列表及清理操作。
5. **权限**：集中查看、请求或前往系统设置调整「屏幕录制」「辅助功能」与「登录时启动」。
6. **关于**：版本信息、系统框架声明，以及基于 GitHub Releases API + SHA-256 校验的内置开源自动更新开关。

## 延伸阅读

- [截图与标注编辑](capture-and-editing.md)
- [文字与截图翻译](translation.md)
- [剪贴板历史](clipboard.md)
- [系统权限说明](permissions.md)
