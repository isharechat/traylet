# 已知限制与防复发规则

## 当前 Beta 前必须保留的限制

- 滚动截图没有实现；`Capture/Scrolling` 与 `Tests/TrayletAppTests/Scrolling` 保留为未完成开发并排除于 MVP 包。
- Vision、系统翻译、语言资源、真实剪贴板采集、前台焦点、物理 IME、VoiceOver、多屏及 macOS 15 最低版本仍需按[验收清单](acceptance.md)分别确认。
- 模糊是视觉效果；不能用于保证安全遮蔽。
- 在线翻译的可用性、账单、内容保留和质量依赖用户所选服务；开发假传输不能证明这些属性。

## 已确认的重复缺陷

### 组装后未重新签名导致应用被判定为损坏

- 现象：Beta 1 的 GitHub Release 包解压后双击提示“已损坏，无法打开”。
- 原因：Swift 链接器只对可执行文件做 ad-hoc 签名；打包脚本随后写入 `Info.plist`、图标和资源 bundle，却没有对完整 `.app` 重新签名，资源封印与实际内容不一致。`codesign --verify --deep --strict` 报 `code has no resources but signature indicates they must be present`。
- 修复：新增 `scripts/assemble-app.sh` 作为唯一组装与签名入口，先写完 `Info.plist` 与资源，再签整个 bundle 并做严格验签；所有打包脚本统一调用它。
- 验证：本地 `scripts/build-from-source.sh` 产物通过 `codesign --verify --deep --strict`；CI 检查包 `41227248721` 同样通过，并在写入 quarantine 后经 `open` 双击路径实际启动成功。回归测试见 `Tests/TrayletToolingTests/test_app_assembly.py`，CI 另有 `scripts/smoke-package.sh` 在上传产物前实际启动打包后的二进制。
- 边界：修复后应用不再被判定损坏，但 ad-hoc 签名仍不受系统安全校验信任，公开下载分发仍需 Developer ID 签名与 Apple 公证。

## 实现防线

- `TranslationSession` 只在当前 SwiftUI `translationTask` 宿主生命周期使用；宿主关闭或配置变化后新建工作，不缓存旧 session。
- macOS 15 路径保护高版本 API；使用 availability 检查，不根据高版本 SDK 可编译推断低版本可用。
- 剪贴板按本次显式同意开启。暂停、设置变化、取消或窗口关闭不得意外补录/恢复旧同意。
- 旧翻译、OCR、归档和收藏加载结果必须核对当前请求/修订身份，防止覆盖较新的输入或复活已删除数据。
- 系统权限与前台窗口只通过正常用户流程验证；不修改 TCC、绕过应用批准或用替代浏览器路径访问受限原型。

历史红绿过程与逐次日志留在维护者本机归档中，不随公开仓库发布，也不作为首个 Beta 的当前验证结果。
