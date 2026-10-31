# 架构与模块

## 结构

Traylet 是单一 SwiftPM macOS 应用：`TrayletApp` 负责界面、系统框架与协调；`TrayletCore` 放跨模块共享值。截图、翻译、剪贴板、设置和本地化按功能划分，不建立全局服务容器来共享窗口或短生命周期系统会话。

```text
Sources/TrayletApp/
  Application/       应用生命周期、菜单、路由、快捷键
  Capture/           屏幕捕获与编辑器入口
  Features/Editing/  编辑状态、画布交互与 PNG 合成
  Features/Translation/ 输入/OCR/翻译协调
  Features/Clipboard/    采集策略、历史、归档与列表
  Settings/          原生设置与偏好入口
  Localization/      界面文案与应用语言
  Evidence/           合成原生取证入口
Sources/TrayletCore/ 共享领域值
```

实际路径以仓库当前目录为准；源文件不会因本图而移动。

## 主要边界

- **编辑器**接收本次捕获或用户选择的图片。预览和输出使用同一合成结果；仅由用户动作复制或保存。
- **翻译**持有输入版本、方向、服务配置和当前请求身份。变化或取消会使旧结果失效。系统 TranslationSession 限于对应 SwiftUI `translationTask` 宿主生命周期。
- **剪贴板**构造与设置展示不等于开始采集。只有本次明确确认后，Native 层才建立 change-count 基线并读取后续内容。
- **存储**使用新版 `~/Library/Application Support/Traylet/v2/` 命名空间，不读取或迁移旧版数据。
- **系统能力**通过 macOS 正常权限流程使用；开发合成测试不改 TCC 或系统安全设置。

## 共享接口

跨模块传递不可变图像/状态值与明确结果，不传递窗口实例、全局 `TranslationSession` 或未完成的用户授权。输出写入失败须保留编辑/历史原件，不通过清空剪贴板或回滚覆盖后来数据。

更改共享值或路由前检查所有调用方、模块文档和对应测试。模块职责见[模块索引](modules/README.md)。
