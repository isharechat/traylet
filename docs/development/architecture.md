# 架构与模块

## 结构

Traylet 是单一 SwiftPM macOS 应用：`TrayletApp` 负责界面、系统框架与协调；`TrayletCore` 放跨模块共享值。截图、翻译、剪贴板、设置和本地化按功能划分，不建立全局服务容器来共享窗口或短生命周期系统会话。

```text
Sources/TrayletApp/
  Application/   应用生命周期、菜单、路由、快捷键、更新
  Capture/       屏幕捕获与编辑器入口（Scrolling/ 未完成，排除构建）
  Editing/       编辑状态、画布交互与 PNG 合成
  Translation/   输入/OCR/翻译协调
  Clipboard/     采集策略、历史、归档与列表
  Settings/      原生设置与偏好入口
  Localization/  界面文案与应用语言
  Shared/        设计、玻璃窗口、权限、选中文本等共享界面能力
  Evidence/      合成原生取证入口
  Resources/     SwiftPM 资源
Sources/TrayletCore/   共享领域值
Tests/TrayletAppTests/ 与源码模块同名的测试目录；Performance/ 为跨模块基准
Tests/TrayletToolingTests/ 脚本与打包工具测试
scripts/
  dev/       swift-local.sh 构建包装、verify-local.sh、构建清单
  package/   assemble-app.sh 统一组装签名、源码构建、本地/CI 打包、冒烟检查
  install/   deliver-local.sh 本地交付与受保护安装器
  homebrew/  Homebrew Cask 模板
assets/brand/  应用图标与品牌标记
```

源码模块目录与测试目录一一对应；新增模块时同时建立两侧目录。类型与文件名不使用版本前缀，新版数据命名空间仅体现在 `Traylet/v2/` 存储路径。

## 主要边界

- **编辑器**接收本次捕获或用户选择的图片。预览和输出使用同一合成结果；仅由用户动作复制或保存。
- **翻译**持有输入版本、方向、服务配置和当前请求身份。变化或取消会使旧结果失效。系统 TranslationSession 限于对应 SwiftUI `translationTask` 宿主生命周期。
- **剪贴板**构造与设置展示不等于异常触发；应用启动时即建立新 change-count 基线并整段运行记录后续内容，不补录启动前内容，退出时停止。
- **存储**使用新版 `~/Library/Application Support/Traylet/v2/` 命名空间，不读取或迁移旧版数据。
- **系统能力**通过 macOS 正常权限流程使用；开发合成测试不改 TCC 或系统安全设置。

## 共享接口

跨模块传递不可变图像/状态值与明确结果，不传递窗口实例、全局 `TranslationSession` 或未完成的用户授权。输出写入失败须保留编辑/历史原件，不通过清空剪贴板或回滚覆盖后来数据。

更改共享值或路由前检查所有调用方、模块文档和对应测试。模块职责见[模块索引](modules/README.md)。
