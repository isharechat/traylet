# 已知限制与防复发规则

## 当前 Beta 前必须保留的限制

- 滚动截图没有实现；`Capture/Scrolling` 与 `Tests/TrayletAppTests/Capture/Scrolling` 保留为未完成开发并排除于当前构建目标。
- Vision、系统翻译、语言资源、真实剪贴板采集、前台焦点、物理 IME、VoiceOver、多屏及 macOS 15 最低版本仍需按[验收清单](acceptance.md)分别确认。
- 模糊是视觉效果；不能用于保证安全遮蔽。
- 在线翻译的可用性、账单、内容保留和质量依赖用户所选服务；开发假传输不能证明这些属性。

## 已确认的重复缺陷

### 组装后未重新签名导致应用被判定为损坏

- 现象：Beta 1 的 GitHub Release 包解压后双击提示“已损坏，无法打开”。
- 原因：Swift 链接器只对可执行文件做 ad-hoc 签名；打包脚本随后写入 `Info.plist`、图标和资源 bundle，却没有对完整 `.app` 重新签名，资源封印与实际内容不一致。`codesign --verify --deep --strict` 报 `code has no resources but signature indicates they must be present`。
- 修复：新增 `scripts/package/assemble-app.sh` 作为唯一组装与签名入口，先写完 `Info.plist` 与资源，再签整个 bundle 并做严格验签；所有打包脚本统一调用它。
- 验证：本地 `scripts/package/build-from-source.sh` 产物通过 `codesign --verify --deep --strict`；CI 检查包 `41227248721` 同样通过，并在写入 quarantine 后经 `open` 双击路径实际启动成功。回归测试见 `Tests/TrayletToolingTests/test_app_assembly.py`，CI 另有 `scripts/package/smoke-package.sh` 在上传产物前实际启动打包后的二进制。
- 边界：修复后应用不再被判定损坏，但 ad-hoc 签名仍不受系统安全校验信任，公开下载分发仍需 Developer ID 签名与 Apple 公证。

### 截图浮层隐藏后残留会话阻止再次截图

- 现象：截图浮层尚未完成圈选时被系统隐藏，但没有触发窗口关闭；之后快捷键无法再次进入截图，退出应用时仍提示“放弃当前截图并退出”。
- 原因：`CaptureEditorController.isOpen` 只判断面板对象是否存在，没有核对窗口是否仍可见。被 `orderOut` 或其他失活路径隐藏的旧 canvas 继续被当作活动编辑会话。
- 修复：截图面板明确 `hidesOnDeactivate = false`；在启动截图、剪贴板图片编辑/翻译和退出判断前，释放“面板存在但不可见”的陈旧会话并完成一次收尾。退出确认只针对实际可见的编辑会话。
- 验证：`hiddenCaptureIsReleasedBeforeAnotherCaptureAndCompletesOnce` 覆盖隐藏会话只完成一次、释放后可重新展示截图。
- 边界：合成测试验证会话状态，不证明真实屏幕失焦、系统隐藏路径、前台窗口视觉或真实全局快捷键行为，仍需系统验收。

### 自动检测短文本被误报为“无法检查系统语言资源”

- 现象：语言包已安装，翻译原文语言为“自动检测”时，输入短文本或无法识别的文本，翻译窗口提示“无法检查系统语言资源，请稍后重试”。
- 原因：系统 `LanguageAvailability.status(for: text, to:)` 在自动识别源语言失败时抛出 `TranslationError.unableToIdentifyLanguage`；控制器把所有检查错误统一映射成资源不可用，掩盖了真实原因。短文本即使目标语言包已安装也会触发该错误。
- 修复：新增 `TranslationLanguageDetector.detectOrInfer`，NaturalLanguage 置信度不足时按书写系统保守回退；`TranslationWork.resolvedSource` 供可用性检查和系统翻译会话使用。真正无法解析的文本改为提示用户选择明确的原文语言；可解析的自动检测文本可在资源缺失页直接准备语言包。
- 验证：`shortAutoTextResolvesToEnglishBeforeAvailabilityCheck`、`shortLatinTextFallsBackToEnglishAndRetargets` 和 `unidentifiableAutoTextUsesActionableFailure` 覆盖短文本回退与失败提示；定向测试 24 个全部通过。
- 边界：书写系统回退是启发式；纯数字、符号或极短歧义文本仍需用户明确选择源语言。真实系统语言包下载、系统翻译会话和前台提示仍需系统验收。

### 输入翻译快捷键在真实前台应用中读不到选中文本

- 现象：在其他应用用鼠标选中文本后按 `⌃⌥R`，翻译窗口正常打开，但原文框为空；应用级、窗口级和 system-wide 三级 `AXFocusedUIElement` 查询都已存在时仍无法预填。
- 原因：该功能依赖 macOS 辅助功能授权。macOS 26 将授权入口放在“隐私与安全性”的“设备控制和数据访问”，本机列表中没有任何 Traylet 条目，`AXIsProcessTrusted()` 为 false，读取在进入焦点查询前就返回无选区。另注意本地构建使用 ad-hoc 签名，指定要求为仅含 `cdhash` 的要求；重新构建后签名哈希变化会使既有授权失效，需要重新授权。
- 修复：快捷键在未授权时每次启动触发一次系统授权提示；翻译窗口显示“无法读取选中文本”的原因和“打开系统设置”按钮；翻译设置的“辅助功能”分区显示授权状态，并提供请求权限或打开系统设置的入口。翻译窗口在下一次展示时清除旧提示。
- 验证：`accessibilityNoticeStaysUntilTheNextPresentation` 覆盖提示生命周期；本机系统设置实查确认 Traylet 无授权条目。未在授权后执行真实前台选区读取，因为授权必须由用户本人确认。
- 边界：必须由用户在系统设置中授权后才能读取选区；每重新签名的 ad-hoc 构建可能需要再次授权。该记录不构成“授权后真实选区已通过”的验收结果。

### 输入翻译快捷键在 Chrome 等应用中读不到选中文本（已授权仍无法预填）

- 现象：辅助功能已授权，在其他应用（尤其 Chrome）选中文本后按 `⌃⌥R`，翻译窗口打开但原文框为空；应用级、窗口级和 system-wide 三级 `AXFocusedUIElement` 查询都没有返回焦点元素。
- 原因：部分应用（如 Chrome）在应用级 `AXFocusedUIElement` 返回无值，窗口级 `AXFocusedUIElement` 返回不支持，system-wide 查询返回 `kAXErrorCannotComplete`；焦点元素解析为空，选区读取在进入角色与选区读取前就结束。
- 修复：采用 Easydict 式分层策略链。无障碍路径保留三级焦点查询与有界遍历，并补上 `AXSelectedTextMarkerRange` + `AXStringForTextMarkerRange` 回退；无障碍读不到时依次尝试浏览器 AppleScript/JS 直读、AX 菜单栏 Copy（`requireEnabled` 预判无选区）、模拟 ⌘C + 剪贴板监听。后两者备份/恢复剪贴板，用 `changeCount` 一致性守卫避免覆盖用户并发复制，并用「忽略下一次复制」排除中间复制污染剪贴板历史。
- 验证：`SelectedTextSafetyTests`、`SelectedTextStrategyTests`、`TranslationControllerTests`、`ShortcutDriverTests`、`AuthorizationGateTests` 定向测试通过；真实 Chrome 前台选区仍需在授权后的实机上确认。
- 边界：该回退依赖应用在焦点窗口子树内暴露 `AXFocused` 或 `AXSelectedTextMarkerRange`；AppleScript 首次使用会触发 macOS「自动化」权限弹窗；⌘C 兜底会短暂改写并恢复系统剪贴板。

### 剪贴板详情悬浮窗首次点击不展示且内容错位

- 现象：历史剪贴板选中第一条详情时悬浮窗不展示或展示慢，选中第二条时展示第一条内容，第三次点击才正常。
- 原因：两个问题叠加。其一，`ClipboardFeature` 用 Combine 订阅 `controller.$selectedID` 同步调用 `syncDetailPanel`，而 `@Published` 在 `willSet` 阶段发布新值——回调执行时 `selectedEntry` 仍是旧值，导致“差一拍”；首次选择读到 `nil` 被当成无选择，直接隐藏悬浮窗。其二，详情 `NSPanel` + `NSHostingView` 在首次选择时才惰性创建，且从未在 `orderFront` 前布局，首次渲染为空/慢。
- 修复：详情面板在 `present()` 时提前构建并完成一次布局；选择变化的回调改为下一 actor turn 再同步，读到已写入的 `selectedEntry`；每次同步前用 `.id(entry.id)` 强制重建详情根视图并在 `orderFront` 前 `layoutSubtreeIfNeeded()`。
- 验证：新增 `detailPopupIsPrebuiltAndReRendersForEachSelection` 覆盖面板预构建与选择切换不残留旧内容；`ClipboardTests`、`ClipboardKeyboardTests` 通过。
- 边界：合成测试验证状态与时序，不证明真实鼠标点击下的窗口合成与首帧延迟，仍需系统验收。

## 实现防线

- `TranslationSession` 只在当前 SwiftUI `translationTask` 宿主生命周期使用；宿主关闭或配置变化后新建工作，不缓存旧 session。
- macOS 15 路径保护高版本 API；使用 availability 检查，不根据高版本 SDK 可编译推断低版本可用。
- 剪贴板整段运行始终记录，从启动后的新 change-count 基线开始，不补录启动前内容；设置变更、清空或窗口关闭不得意外覆盖未加载的归档。
- 旧翻译、OCR、归档和收藏加载结果必须核对当前请求/修订身份，防止覆盖较新的输入或复活已删除数据。
- 系统权限与前台窗口只通过正常用户流程验证；不修改 TCC、绕过应用批准或用替代浏览器路径访问受限原型。

历史红绿过程与逐次日志留在维护者本机归档中，不随公开仓库发布，也不作为首个 Beta 的当前验证结果。
