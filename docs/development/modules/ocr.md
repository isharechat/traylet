# OCR 模块

**实现目录：** `Sources/TrayletApp/OCR/`  
**测试目录：** `Tests/TrayletAppTests/OCR/`

负责独立截图 OCR、导入图片识别、本机 Vision 与多模态 AI OCR 双引擎调度、文本后处理（合并换行/自动复制）以及与翻译、截图编辑器之间的跨模块跳转。

## 核心行为与数据流

```text
菜单栏 / 快捷键 (⌃⌥O) ─▶ 区域选区 (OCR 模式) ──┐
截图编辑器「OCR」按钮 (保留编辑器) ─────────────┼─▶ OCRController ─▶ Vision / AI OCR ─▶ 结果区
翻译窗口「截图 OCR / 拖入图片 / 查看原图」 ────┘        ▲                    │
                                                          └──── 双向跳转 ──────▼
                                                                      TranslationController
```

1. **触发入口**：
   - 菜单栏与全局快捷键新增独立的「OCR 识别」（默认 `⌃⌥O`），进入选区后显示「识别所选区域」并打开 OCR 窗口。
   - 截图编辑器工具栏新增「OCR」按钮，对当前裁切/标注区域执行识别并弹出 OCR 窗口，**不关闭编辑器**以便继续标注（此时 OCR 窗口提升至编辑器之上）。
   - 翻译窗口支持点击「截图 OCR / 查看原图」或直接拖入图片跳转至 OCR 窗口。
2. **页面布局（左右分栏）**：
   - **左侧原图预览区（可折叠）**：支持缩放（`-` / `+` / 适应）、重新截图、导入本地图片或拖拽图片文件，收起后右侧自动扩展为纯文本视图。
   - **右侧识别文本区**：顶部提供引擎切换（本机 Vision / AI OCR）、AI 预设模式选择（纯文本 / Markdown 表格 / 数学公式 / 自定义）、重新识别与设置跳转；正文为可编辑 `TextEditor`；底部浮动玻璃胶囊提供朗读、复制、合并换行、清空及主操作「去翻译」（`⌘↩`）。
3. **双引擎与文本后处理**：
   - **本机 Vision（默认，离线）**：复用 `TranslationVisionOCR`，支持高精度/快速模式开关。
   - **AI OCR（按需外发）**：通过 OpenAI 兼容 `chat/completions` 多模态接口发送 `image_url`（Base64 PNG Data URI）与系统 Prompt；内置纯文本、Markdown 表格、数学公式（LaTeX）与自定义 Prompt 四种预设。
   - **后处理**：支持保留空行（`\n\n`）的智能合并换行（CJK 相邻直接拼接，西文插入空格），以及识别完成后自动复制到剪贴板。

## 配置与持久化

- 配置文件：`~/Library/Application Support/Traylet/v2/ocr.json`（原子写入，`0o600` 权限，拒绝符号链接，支持损坏备份恢复）。
- 凭据存储：独立 API Key 存入 macOS 钥匙串（`local.traylet.app.ocr` / `ocr-ai-api-key`），不写入明文 JSON。
- **复用翻译 AI 配置**：默认开启「复用翻译的 AI 接口与凭据」，直接读取 `TranslationConfiguration` 的 Endpoint 与 Keychain 凭据，并允许在 OCR 设置中单独覆盖视觉模型名称或 Prompt。

## 边界

- AI OCR 仅在用户显式选择 AI 引擎、点击重新识别或诊断测试时向已配置端点发送请求，不自动后台上传。
- 测试默认使用 fake HTTP 传输、fake 剪贴板写入与 fake 语音；真实 AI 视觉模型质量、系统快捷键及多显示器窗口层级需按[发布验收清单](../acceptance.md)单独验证。
