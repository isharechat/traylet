# 架构与模块

Traylet 是一个基于 Swift 6 与 SwiftPM 构建的纯原生 macOS 应用，无第三方 Swift 包依赖。

## 目录结构

```text
Sources/
  TrayletApp/
    Application/   应用生命周期、菜单栏、路由、全局快捷键与自动更新
    Capture/       屏幕捕获与编辑器入口
    Editing/       标注状态、画布交互、浮动工具栏与 PNG 合成
    OCR/           独立 OCR 窗口、Vision / AI OCR 双引擎与文本后处理
    Translation/   划词/输入/截图翻译调度与系统语言包管理
    Clipboard/     剪贴板采集、本机归档、搜索筛选与详情浮窗
    Settings/      原生设置窗口（通用、快捷键、翻译、OCR、剪贴板、权限、关于）
    Localization/  中英文界面文案与语言切换
    Shared/        设计令牌、Liquid Glass 容器、权限与选区读取策略
    Evidence/      合成原生布局取证入口
    Resources/     应用图标等静态资源
  TrayletCore/     跨模块共享领域模型
Tests/
  TrayletAppTests/     按模块对应的 Swift Testing 单元测试
  TrayletToolingTests/ 打包、组装与脚本工具的 Python 单元测试
scripts/
  dev/             swift-local.sh 构建包装与本地验证脚本
  package/         assemble-app.sh 统一组装签名、源码构建、本地/CI 打包与冒烟检查
  install/         deliver-local.sh 本地安全安装与交付脚本
  homebrew/        Homebrew Cask 模板
assets/brand/      应用图标与品牌矢量资产
```

## 模块职责与边界

- **Application**：管理状态栏菜单、全局快捷键、权限失效重授权提醒与 GitHub Releases SHA-256 更新检查，负责各功能模块的桥接跳转。
- **Capture & Editing**：捕获区域或整屏图像后交由 `EditingSession` 维护选区、标注对象与撤销栈。预览与导出共用同一合成管线，仅由明确用户动作触发复制、保存、翻译、OCR 或悬浮置顶。
- **OCR**：独立管理识别结果与原图预览，支持本机 Vision 与 OpenAI 兼容 AI OCR（配置独立存于 `~/Library/Application Support/Traylet/v2/ocr.json` 与钥匙串），切换引擎时自动清空旧结果并重新识别。
- **Translation**：维护输入版本、语种方向、服务配置与请求身份；输入或配置变更立即使在途请求失效。Apple 系统翻译会话绑定于对应 SwiftUI `translationTask` 宿主生命周期。
- **Clipboard**：启动时记录系统剪贴板 `changeCount` 基线，仅采集运行期间的新内容并写入 `~/Library/Application Support/Traylet/v2/clipboard`，退出时停止。
- **Shared & Settings**：提供 `Design` 尺寸令牌、`GlassSurface` / `GlassWindowBacking` 材质适配以及基于 macOS 原生流程的权限检查与引导。

## 本地构建与测试

```sh
# 编译
scripts/dev/swift-local.sh build

# 运行 Swift 单元测试（排除需人工/系统色盘交互的 EditingColorWellTests）
scripts/dev/swift-local.sh test --no-parallel --skip EditingColorWellTests

# 运行脚本与打包工具测试
python3 -m unittest discover -s Tests/TrayletToolingTests
```
