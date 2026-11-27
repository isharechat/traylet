# 快速上手

Traylet 常驻在 macOS 顶部菜单栏，围绕日常高频的截图编辑、翻译、OCR 识别与剪贴板历史四项任务设计，强调本机离线优先与原生交互体验。

## 系统要求

- **操作系统**：macOS 15 或更高版本
- **架构**：Apple Silicon（`arm64`）
- **源码构建额外要求**：Swift 6 工具链与 Python 3

## 安装方式

### 1. 从 GitHub Releases 下载

前往 [GitHub Releases](https://github.com/isharechat/traylet/releases) 下载 `Traylet-macos-arm64-*.zip` 与对应的 `.sha256` 校验文件：

```sh
shasum -a 256 -c Traylet-macos-arm64-*.zip.sha256
```

校验通过后解压，将 `Traylet.app` 拖入「应用程序（`/Applications`）」文件夹。

> 提示：若下载的是未经 Apple 公证的 `-preview` 预览包，首次打开时 macOS Gatekeeper 可能会拦截。可在「访达」中按住 `Control` 键右键点击 `Traylet.app` 选择「打开」，或在终端运行 `xattr -cr /Applications/Traylet.app` 后再启动。

### 2. 从源码构建

```sh
git clone https://github.com/isharechat/traylet.git
cd traylet
scripts/package/build-from-source.sh
```

脚本会完成编译、资源组装与本机 ad-hoc 签名，产物位于 `build/source/Traylet.app`，拖入 `/Applications` 即可运行。

### 3. Homebrew Cask

仓库在 `scripts/homebrew/traylet.rb` 提供了 Homebrew Cask 模板，可用于自建 Tap 分发。

## 菜单栏入口

启动后点击菜单栏中的 Traylet 图标，可快速访问以下功能：

- **区域截图** / **屏幕截图**
- **输入翻译** / **截图翻译**
- **OCR 识别**
- **剪贴板**
- **设置**（`⌘,`）
- **退出**（`⌘Q`）

## 默认全局快捷键

所有全局快捷键均可在「设置 → 快捷键」中自定义录制或清除：

| 功能 | 默认快捷键 | 说明 |
| --- | --- | --- |
| 区域截图 | `⌃⌥⇧A` | 框选屏幕区域并打开标注编辑器 |
| 屏幕截图 | `⌃⌥⇧S` | 截取整屏并打开标注编辑器 |
| 输入翻译 | `⌃⌥⇧T` | 打开翻译窗口并尝试预填前台选中文本 |
| 截图翻译 | `⌃⌥⇧R` | 框选区域进行本机 OCR 并翻译 |
| OCR 识别 | `⌃⌥⇧O` | 框选区域并打开独立 OCR 识别窗口 |
| 剪贴板 | `⌃⌥⇧V` | 打开剪贴板历史浮窗 |

## 设置概览

按 `⌘,` 或从菜单栏进入「设置」，包含七个分区：

1. **通用**：应用语言（跟随系统 / 简体中文 / English）、外观（跟随系统 / 浅色 / 深色）与 Liquid Glass 材质开关。
2. **快捷键**：全局快捷键录制、冲突检测与恢复默认。
3. **翻译**：Apple 系统语言包管理、默认翻译引擎、外部服务配置与辅助功能状态。
4. **OCR**：本机 Vision 与 AI OCR 配置、模型与 Prompt 预设、换行合并与自动复制。
5. **剪贴板**：记录类型、数量上限、保留期限、排除应用（Bundle ID）与清理操作。
6. **权限**：集中查看与管理「屏幕录制」「辅助功能」与「登录时启动」。
7. **关于**：版本信息、框架声明与内置开源自动更新检查。

## 延伸阅读

- [截图与标注编辑](capture-and-editing.md)
- [文字与截图翻译](translation.md)
- [OCR 文字识别](ocr.md)
- [剪贴板历史](clipboard.md)
- [系统权限说明](permissions.md)
