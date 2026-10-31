# 翻译模块

**实现目录：** `Sources/TrayletApp/Features/Translation/`  
**测试目录：** `Tests/TrayletAppTests/Translation/`

负责输入翻译、截图/历史图片 OCR、翻译配置与请求生命周期。

## MVP 行为

- 默认系统翻译；OCR 使用本机 Vision。
- 用户可编辑 OCR 原文，再明确提交翻译。
- 外部服务由用户选择；展示目标与正文后发送。配置变化或窗口关闭会撤销旧确认。
- 输入、方向、配置或取消变化后，旧工作不能覆盖当前结果。
- 凭据当前只在内存中，不写普通配置文件。

## 生命周期

系统 `TranslationSession` 限于当前 SwiftUI `translationTask` 宿主。不把 session 缓存在全局对象或复用到已关闭/配置已变的窗口。macOS 15 路径使用可用 API。

测试默认采用 fake 网络、资源和语音。真实系统翻译、下载、外部质量及服务条款需单独验收。
