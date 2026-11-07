# 验证记录

## 当前修正版 Beta 状态

- 修正版目标为 `0.1.0-beta.2` / build `2`；对应值已写入 `VERSION` 与 `BUILD_NUMBER`，CI tag 仍须与 `VERSION` 完全相等。
- 对已发布的 Beta 1 ZIP 做了 SHA-256 检查，结果通过；解包后 `codesign --verify --deep --strict` 报告 `code has no resources but signature indicates they must be present`。原因是组装 `.app` 后没有重新签整个 bundle，macOS 因此提示应用已损坏。
- Beta 1 Release 已转为草稿并标注不可用，旧下载资产未删除，以保留追溯证据。
- 已修正 CI 包脚本：完成 Info.plist 和资源组装后签名整个 `.app`，并严格验证资源封印。手动 CI 产物使用 ad-hoc 签名，仅供检查，不受 Gatekeeper 信任。
- 公开 Beta 2 流程已设为失败关闭：需要 Developer ID Application P12 和 App Store Connect API key；签名后提交 Apple 公证、staple 票据、运行 `codesign` 与 `spctl` 验证，全部成功才创建 Release。
- 当前开发机 `security find-identity` 找到 0 个有效签名身份，GitHub 仓库没有配置所需签名/公证 secrets。Beta 2 检查包 CI `41226136185` 的 Swift/Python 测试、ZIP SHA-256 与完整 app 签名封印验证通过；因其为 ad-hoc 签名，`spctl` 按预期拒绝，未作为 Release 发布。Developer ID 签名和公证仍未完成，不能承诺可供公众下载运行。
- Beta 1 的 CI 编译和 Swift/Python 测试曾通过，但不构成当前 Beta 2 的签名、公证或系统运行验证。真实权限、视觉、安装和应用功能验收仍待完成。
- 已抽出 `scripts/assemble-app.sh` 作为唯一的应用组装与签名入口，`build-from-source.sh`、`package-local.sh`、`package-ci.sh` 都调用它，避免再次出现只签二进制、缺少资源封印的包。
- 本地实测：`scripts/build-from-source.sh` 成功产出 `build/source/Traylet.app`；`codesign --verify --deep --strict` 通过，`Sealed Resources version=2 rules=13 files=8`，`Info.plist` 为 `0.1.0` / build `2` / `0.1.0-beta.2`，无 quarantine 属性，二进制以 `--v2-native-evidence` 启动并正常退出（exit 0）。
- 本机当前工作区的 Swift 测试 `scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests`：357 个测试、72 个 suite；330 个通过、20 个跳过、7 个失败（12 个 issue，均为沙箱禁止真实系统 pasteboard 写入）。Python 工具测试 40 个全部通过，其中 `test_app_assembly.py` 覆盖资源封印回归。
- Beta 2 仍未发布为公开 Release：缺少 Developer ID 证书与公证凭据，Gatekeeper 信任未建立。

## Beta 2 下载包实机验证（2026-11-01）

以 CI 检查包 `41227248721` 的产物为对象，走「下载 → 解压 → 双击」路径实机验证：

- 下载 `Traylet-macos-arm64-v0.1.0-beta.2-build2.zip`，SHA-256 校验通过。
- 解压后 `codesign --verify --deep --strict` 通过，资源封印有效（`Sealed Resources version=2 rules=13 files=8`）。
- 在 `~/Downloads` 下解包并写入 `com.apple.quarantine` 隔离属性（模拟浏览器下载），`open`（等价于双击）启动成功，进程正常运行，未出现「已损坏」提示，退出码为 0。
- 直接执行二进制与 `open` 启动两条路径都通过；系统日志中没有对应的 Gatekeeper 拒绝记录。
- 新增 `scripts/smoke-package.sh`：解包归档、严格验签、核对 `TrayletReleaseVersion` 与 `VERSION` 一致、并以 `--v2-native-evidence` 实际启动打包后的二进制。CI 在上传 artifact 前执行该脚本，避免「签名结构正确但运行失败」的包流入下游。

边界：该包为 ad-hoc 签名，`spctl --assess --type execute` 按预期拒绝（`Invalid argument`）。因此它可以作为源码/结构检查与本机运行的可信来源，但**不能**作为对公众分发、让陌生用户双击安装的正式包。公开分发仍需 Developer ID 签名加 Apple 公证。系统日志未出现拒绝记录不等于 Apple 已接受该包；未做真实第三方机器的干净环境安装验收。

## 预览 Release 实测（2026-11-01）

预览通道 `v0.1.0-beta.2-preview` 的 Release 已发布（CI run `41229278881` 成功），资产为 `Traylet-macos-arm64-v0.1.0-beta.2-build2.zip` 与对应 `.sha256`。从 Release 下载后实测：

- SHA-256 校验通过；`codesign --verify --deep --strict` 通过。
- 包内元数据正确：`TrayletReleaseVersion=0.1.0-beta.2`、`CFBundleVersion=2`。
- 放入 `~/Downloads`、写入 `com.apple.quarantine` 隔离属性后，`open`（等价双击）启动成功，进程持续运行，`System Events` 可见 `Traylet` 菜单栏状态项（`Apple, Traylet, 编辑`），未出现「已损坏」提示。
- 结论：Beta 1 的「已损坏」问题在 Beta 2 预览包上已不复现，用户可正常下载解压并启动。

边界：该包为 ad-hoc 签名、无公证票据，属于预览通道，Release 说明中已标注。普通用户在干净机器上仍可能遇到「无法验证开发者」，此时应改用 `scripts/build-from-source.sh`。正式签名版仍待 Developer ID 凭据配置后用正式 tag 发布。真实第三方机器的安装验收尚未进行。

## 剪贴板改为整段运行默认开启（2026-11-02）

产品改动：剪贴板历史从「每次运行默认关闭、逐次确认」改为「整段运行默认开启」，移除运行时开启/关闭与暂停/恢复开关（仅退出时停止）。同步更新 `AGENTS.md`、`README.md`、`docs/product/mvp.md`、`docs/development/privacy.md`、`acceptance.md`、`glossary.md`、`modules/clipboard.md`，并删除不再使用的确认流与暂停代码、对应测试。

命令与退出码（本地开发机，macOS Apple Silicon；测试在沙箱内运行）：

- `scripts/swift-local.sh build`：退出码 0，Build complete。
- `scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests`：退出码 1。共 340 个测试、71 个 suite。
  - 通过：其余全部通过（340 中扣除下列跳过/失败/排除后）。
  - 跳过（20，环境性，不计入通过）：离屏合成截图取证（`TRAYLET_*_DIR` 未设置，如 `syntheticBaseline`、`renderIcons`、`clipboardRowDisplay` 等）、`writesSyntheticNativeViews`（显式合成动作）、`nativePreviewExposesEnglishActionsWhenAXTreeIsAvailable`（AX 树不可用）、`recognizesSyntheticPrintedEnglish`（需 CoreVideo）、`translationTypingIntoLongText` 等。
  - 排除：`EditingColorWellTests`（按命令显式跳过，整组不执行）。
  - 失败（12 个 issue，集中在 7 个测试 / 3 个 suite）：`Clipboard Private Pasteboard`（8 issue）、`Clipboard Capture Controls`（3 issue）、`Clipboard Plain Text`（1 issue）。全部失败在同一处：`board.setString` / `board.writeObjects` / `native.write` 返回 `.failed`，即沙箱阻止对真实系统剪贴板/pasteboard 的写入。这是环境阻塞，非产品回归，与本改动无关（改动前全量跑即有同样的 12 个失败）。本机无沙箱环境重跑即可消除。
- `python3 -m unittest discover -s Tests/TrayletToolingTests`：退出码 0，40 个测试全部通过。

打包与冒烟（本机 ad-hoc 构建，`build-from-source.sh`）：

- 产出 `build/source/Traylet.app`；包内元数据 `CFBundleShortVersionString=0.1.0`、`CFBundleVersion=2`、`TrayletReleaseVersion=0.1.0-beta.2`、Bundle ID `local.traylet.app`。
- `codesign --verify --deep --strict` 通过，`Signature=adhoc`，`Sealed Resources version=2 rules=13 files=8`。
- ZIP `build/Traylet-local-smoke.zip`（4.4 MB），SHA-256 `17acf7fe9846c3bc2b0c99ad9a4492adc77fa5f1d6ce3603b3f5f3fdb4a387c4`。
- `scripts/smoke-package.sh build/Traylet-local-smoke.zip`（沙箱外运行，以连接 WindowServer）：退出码 0，解包、严格验签、版本核对、`--v2-native-evidence` 实际启动打包二进制均通过，输出 "Synthetic native evidence completed" / "Smoke test passed"。

边界：该包为 ad-hoc 签名、无公证票据，仅证明本机源码构建可组装、可验签、可启动；不构成 Developer ID 签名、Apple 公证、Gatekeeper 信任或真实剪贴板整段记录/退出停止/玻璃质感的系统验收，也不放行公开分发。真实权限与前台行为仍待实机验收。

## 翻译设置直连诊断与配置持久化（2026-11-02）

产品改动：

- “获取模型”和“测试连接”不再打开确认 sheet；按钮内显示进行中、成功或失败，失败原因放在按钮提示与辅助功能值中。
- 获取到的模型直接从“模型”输入框旁的菜单选择，移除独立“搜索模型”输入框和下方列表，移除“固定短文测试”按钮。
- 翻译设置写入 `translation.json`；AI 与 DeepL 凭据写入 macOS 钥匙串，恢复默认设置时清除。剪贴板记录已从设置页移除。

命令与结果（本地开发机，macOS Apple Silicon；测试在沙箱内运行）：

- `scripts/swift-local.sh build`：退出码 0，Build complete。
- `scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests`：退出码 1。共 348 个测试、71 个 suite；除下列 12 个环境性失败外其余通过，另有显式跳过/排除项。
  - 失败（12 个 issue，集中在 3 个 suite）：`Clipboard Private Pasteboard`（8）、`Clipboard Capture Controls`（3）、`Clipboard Plain Text`（1）。均为沙箱阻止对真实系统剪贴板/pasteboard 的写入，与本轮翻译设置改动无关。
  - 排除：`EditingColorWellTests`（按命令显式跳过）。
- `python3 -m unittest discover -s Tests/TrayletToolingTests`：退出码 0，40 个测试全部通过。
- `TRAYLET_REWRITE_TRANSLATION_EVIDENCE_DIR=/tmp/traylet-translation-evidence scripts/swift-local.sh test --no-parallel --filter TranslationEvidenceTests`：退出码 0，生成翻译设置深浅色离屏合成图；确认模型下拉入口、按钮成功状态与中英文布局。该结果仅证明合成视图布局，不证明真实前台窗口或系统材质。

打包与冒烟（`scripts/build-from-source.sh`）：

- 产出 `build/source/Traylet.app`；包内元数据 `CFBundleShortVersionString=0.1.0`、`CFBundleVersion=2`、`TrayletReleaseVersion=0.1.0-beta.2`、Bundle ID `local.traylet.app`。
- `codesign --verify --deep --strict` 通过；`Signature=adhoc`，`TeamIdentifier=not set`。
- ZIP `build/Traylet-local-smoke.zip`（4.4 MB，4,657,847 bytes），SHA-256 `54d6cbb111af9b9dd9e126b793fd9c3b1212eed5b7e4bb511ec2557258009821`。
- `scripts/smoke-package.sh build/Traylet-local-smoke.zip`（沙箱外运行）：退出码 0，完成解包、严格验签、版本核对，并实际启动包内二进制生成合成证据，输出 "Synthetic native evidence completed" / "Smoke test passed"。

边界：该包为 ad-hoc 签名、无公证票据，仅证明本机源码可构建、可验签、可启动，不构成 Developer ID 签名、Apple 公证或 Gatekeeper 信任。未验证真实外部翻译服务、真实钥匙串 UI、前台设置窗口的玻璃材质及系统级交互。

## 翻译设置模型下拉搜索（2026-11-03）

产品改动：翻译设置的“模型”字段改为自定义下拉面板，下拉按钮默认常显；支持输入搜索（忽略大小写并去除首尾空白）、匹配计数、无结果提示、清除搜索和 Esc 关闭；选择模型后回填并关闭面板，获取模型成功后自动展开。点击“获取模型”后焦点自动移到模型输入框。尚未获取模型时，面板显示空状态并提示先点击“获取模型”。原先的原生 `Menu` 已移除，`docs/development/modules/translation.md` 同步更新。

缺陷修复：焦点从“服务地址”切到“模型”时，AppKit 会把未变化的地址同值回写；此前这会触发设置变更并取消正在执行的获取任务，表现为“获取失败”。现在同值回写不再触发变更或取消，并新增 `sameValueFocusWriteBackDoesNotCancelSettingsAction` 覆盖该路径。

视觉调整：Google 与 DeepL 的官方矢量路径从实心填充改为同色圆角描边，线宽随图标尺寸缩放，与其余 SF Symbol 图标的单色风格和视觉重量保持一致；合成图标快照补充 48/18/16pt 三档用于逐档目视检查。

命令与结果（本地开发机，macOS Apple Silicon；测试在沙箱内运行）：

- `scripts/swift-local.sh build`：退出码 0，Build complete。
- `scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests`：退出码 1。共 350 个测试、71 个 suite；除下列 12 个环境性失败外其余通过，另有显式跳过/排除项。
  - 失败（12 个 issue，集中在 3 个 suite）：`Clipboard Private Pasteboard`（8）、`Clipboard Capture Controls`（3）、`Clipboard Plain Text`（1）。均为沙箱阻止对真实系统剪贴板/pasteboard 的写入，与本轮模型下拉改动无关。
  - 排除：`EditingColorWellTests`（按命令显式跳过）。
- `python3 -m unittest discover -s Tests/TrayletToolingTests`：退出码 0，40 个测试全部通过。
- `TRAYLET_REWRITE_TRANSLATION_EVIDENCE_DIR=/tmp/traylet-translation-evidence scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests --filter TranslationEvidenceTests`：退出码 0；已目视检查下拉面板深浅色布局、搜索入口、选中/悬停状态与未获取模型时的空状态。该结果仅证明合成视图布局，不证明真实前台窗口或系统材质。

打包与冒烟（`scripts/build-from-source.sh`）：

- 产出 `build/source/Traylet.app`；包内元数据 `CFBundleShortVersionString=0.1.0`、`CFBundleVersion=2`、`TrayletReleaseVersion=0.1.0-beta.2`、Bundle ID `local.traylet.app`。
- `codesign --verify --deep --strict` 通过；`Signature=adhoc`，`TeamIdentifier=not set`。
- ZIP `build/Traylet-local-smoke.zip`（4.5 MB，4,732,386 bytes），SHA-256 `8f73cf0a0b76215bb8d999a94cf4edbeae83ddd2124ae9afa9cddd7083c464fa`。
- `scripts/smoke-package.sh build/Traylet-local-smoke.zip`（沙箱外运行）：退出码 0，完成解包、严格验签、版本核对，并实际启动包内二进制生成合成证据，输出 "Synthetic native evidence completed" / "Smoke test passed"。

边界：该包为 ad-hoc 签名、无公证票据，仅证明本机源码可构建、可验签、可启动，不构成 Developer ID 签名、Apple 公证或 Gatekeeper 信任。未验证真实外部翻译服务、真实前台设置窗口的下拉交互与系统材质。

## 剪贴板本机保存、选择详情与设置玻璃（2026-11-03）

产品改动：

- 剪贴板普通历史与收藏始终写入 `~/Library/Application Support/Traylet/v2/clipboard` 的未加密归档，启动时加载并在重启后恢复；移除本机保存开关及旧确认流程。设置页固定显示保存路径、未加密提示和清理边界。
- 悬浮剪贴板移除“展开详情”图标按钮。列表不自动选中条目；鼠标点击或键盘选择后才展开详情列，选中项被隐藏、清空或删除时收起并恢复窄窗。窗口宽度随选择同步。
- 设置侧栏移除独立底色，左右两栏共同绘制窗口玻璃；玻璃模式保留两栏分割线，实体模式保持单一连续平面。
- 翻译设置沿用本轮已记录的直连诊断、配置持久化、可搜索模型下拉、焦点修复和 Google/DeepL 同色描边图标改动。

命令与结果（本地开发机，macOS Apple Silicon；Swift 测试在沙箱内运行）：

- `scripts/swift-local.sh build` / `scripts/build-from-source.sh`：退出码 0，Build complete，应用组装和 ad-hoc 签名成功。
- `scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests`：退出码 1。349 个测试、71 个 suite；322 个通过、20 个跳过、7 个失败（12 个 issue）。
  - 失败集中在 `Clipboard Private Pasteboard`（8 issue）、`Clipboard Capture Controls`（3 issue）、`Clipboard Plain Text`（1 issue），均为沙箱阻止真实系统剪贴板/pasteboard 写入，与本轮改动无关。
  - 排除：`EditingColorWellTests`（按命令显式跳过）。
- `python3 -m unittest discover -s Tests/TrayletToolingTests`：退出码 0，40 个测试全部通过。
- `TRAYLET_CLIPBOARD_SNAPSHOT_DIR=/tmp/traylet-clipboard-evidence scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests --filter 'ClipboardVisualTests|ClipboardImageEvidenceTests'`：退出码 0，2 个测试通过。已目视检查无选择列表、选中详情、深浅色与英文图片操作布局；确认右侧展开按钮已移除。
- `TRAYLET_SETTINGS_SURFACE_DIR=/tmp/traylet-settings-surface scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests --filter SettingsSurfaceTests`：退出码 0，1 个测试通过；已目视检查设置侧栏与详情栏玻璃一致、玻璃模式分割线可见。
- `TRAYLET_REWRITE_TRANSLATION_EVIDENCE_DIR=/tmp/traylet-translation-evidence TRAYLET_ICON_SNAPSHOT=/tmp/traylet-translation-icons.png scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests --filter 'TranslationEvidenceTests|TranslationEnginesTests'`：退出码 0，14 个测试、4 个 suite 通过；已目视检查模型下拉、获取成功状态和三档图标。

打包与冒烟（`scripts/build-from-source.sh`）：

- 产出 `build/source/Traylet.app`；包内元数据 `CFBundleShortVersionString=0.1.0`、`CFBundleVersion=2`、`TrayletReleaseVersion=0.1.0-beta.2`、Bundle ID `local.traylet.app`。
- `codesign --verify --deep --strict` 通过；`Signature=adhoc`，`TeamIdentifier=not set`。
- ZIP `build/Traylet-local-smoke.zip`（4,727,143 bytes），SHA-256 `9f4855141b3a7e09220ad740b246a0cd706aa9d6dd912a0be8c2644bb47b565e`。
- `scripts/smoke-package.sh build/Traylet-local-smoke.zip`：沙箱内因无法连接 WindowServer 退出 134；按打包流程在沙箱外运行退出 0，完成解包、严格验签、版本核对和实际启动，输出 "Synthetic native evidence completed" / "Smoke test passed"。

边界：该包为 ad-hoc 签名、无公证票据，仅证明本机源码可构建、可验签、可启动，不构成 Developer ID 签名、Apple 公证或 Gatekeeper 信任。合成截图不证明真实前台窗口、WindowServer 材质、物理鼠标/键盘或真实系统剪贴板采集；这些仍需系统验收。

## 截图浮层隐藏后的会话恢复（2026-11-07）

问题：截图浮层在尚未完成圈选时被隐藏但窗口没有关闭，旧的编辑会话仍被判定为打开，导致再次截图被静默拒绝，退出时还会误问是否放弃未完成截图。

修复：截图面板禁止失活自动隐藏；新增陈旧会话清理，在截图、剪贴板图片编辑/翻译入口及退出判断前，释放窗口已不可见但尚未关闭的编辑器和画布。退出确认只对仍可见的截图会话弹出。

命令与结果（本地开发机，macOS Apple Silicon；Swift 测试在沙箱内运行）：

- `scripts/swift-local.sh build`：退出码 0，Build complete。
- `scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests --filter ImportedImageTests`：退出码 0，8 个测试、1 个 suite 通过；包含新增的隐藏会话回归测试。
- `scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests`：退出码 1。共 350 个测试、71 个 suite；323 个通过、20 个跳过、7 个失败（12 个 issue）。
  - 失败仍集中在 `Clipboard Private Pasteboard`（8 issue）、`Clipboard Capture Controls`（3 issue）、`Clipboard Plain Text`（1 issue），均为沙箱阻止真实系统剪贴板/pasteboard 写入，与本轮截图会话修复无关。
  - 排除：`EditingColorWellTests`（按命令显式跳过）。
- `python3 -m unittest discover -s Tests/TrayletToolingTests`：退出码 0，40 个测试全部通过。

打包与冒烟（`scripts/build-from-source.sh`）：

- 产出 `build/source/Traylet.app`；`codesign --verify --deep --strict` 通过，包内元数据为 `0.1.0` / build `2` / `0.1.0-beta.2`。
- ZIP `build/Traylet-local-smoke.zip`（4,727,330 bytes），SHA-256 `5418a0a191bc2aa918e1bb6ff9f4a68ba39acd3e59fc3689eefac62437a17ea9`。
- `scripts/smoke-package.sh build/Traylet-local-smoke.zip`：沙箱外退出码 0，完成解包、严格验签、版本核对和包内二进制实际启动，输出 "Synthetic native evidence completed" / "Smoke test passed"。

边界：新增回归测试使用注入的隐藏面板模拟陈旧会话，不证明真实系统截图浮层的失活、系统隐藏、前台焦点或全局快捷键路径；这些仍需按[验收清单](acceptance.md)实机确认。

## 翻译系统语言包设置与缺失跳转（2026-11-07）

产品改动：

- 设置页新增“系统语言包”分区，可选择原文/译文语言，检查系统翻译资源并提前下载；状态覆盖未检查、检查中、已安装、可下载、不支持、下载中和失败，下载完成后自动重新检查。
- 下载只通过系统 `TranslationSession.prepareTranslation()` 的一次性宿主执行；切换语言、下载失败或页面消失会使旧请求失效。Traylet 不直接下载、读取或保存语言包文件。
- 翻译窗口语言资源缺失时保留“直接准备并翻译”，新增“前往设置下载语言包”。跳转打开翻译设置并预填当前语言对；原文为自动检测时使用已检测语言，未检测出时保留设置页现有选择。
- 同步更新[翻译模块](modules/translation.md)、[数据与隐私](privacy.md)、[MVP 范围](../product/mvp.md)和[验收清单](acceptance.md)。

命令与结果（本地开发机，macOS Apple Silicon；Swift 测试在沙箱内运行）：

- `scripts/swift-local.sh build`：退出码 0，Build complete。
- `scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests`：退出码 1。354 个测试、72 个 suite；327 个通过、20 个跳过、7 个失败（12 个 issue）。
  - 失败仍集中在 `Clipboard Private Pasteboard`（8 issue）、`Clipboard Capture Controls`（3 issue）、`Clipboard Plain Text`（1 issue），均为沙箱阻止真实系统剪贴板/pasteboard 写入，与本轮语言包改动无关。
  - 排除：`EditingColorWellTests`（按命令显式跳过）。
- `python3 -m unittest discover -s Tests/TrayletToolingTests`：退出码 0，40 个测试全部通过。
- `TRAYLET_REWRITE_TRANSLATION_EVIDENCE_DIR=/tmp/traylet-language-pack-evidence scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests --filter TranslationEvidenceTests`：退出码 0，1 个测试、1 个 suite 通过，生成翻译设置与缺失状态离屏合成图。已目视检查：
  - `/tmp/traylet-language-pack-evidence/translation-ai-settings-light.png`：系统语言包分区、语言选择、状态、检查/下载按钮与隐私说明布局正常。
  - `/tmp/traylet-language-pack-evidence/translation-window-language-pack-missing.png`：缺失提示、两个操作按钮和说明在 520×500 窗口内完整显示，无溢出。

打包与冒烟（`scripts/build-from-source.sh`）：

- 产出 `build/source/Traylet.app`；`codesign --verify --deep --strict` 通过，包内元数据为 `0.1.0` / build `2` / `0.1.0-beta.2`。
- ZIP `build/Traylet-local-smoke.zip`（4,779,714 bytes），SHA-256 `cb1c69a68d00a5d37891eacc28b2a143ffa4f8c0361e4d61dd71746e38f86664`。
- `scripts/smoke-package.sh build/Traylet-local-smoke.zip`：沙箱外退出码 0，完成解包、严格验签、版本核对和包内二进制实际启动，输出 "Synthetic native evidence completed" / "Smoke test passed"。

边界：语言包测试使用注入的资源检查与下载宿主；离屏合成图只证明视图布局。未验证真实系统语言包检查/下载、系统确认 UI、网络失败、真实前台设置按钮点击或翻译窗口到设置的跳转；这些仍需按[验收清单](acceptance.md)实机确认。该包为 ad-hoc 签名、无公证票据，仅证明本机源码可构建、可验签、可启动，不构成 Developer ID 签名、Apple 公证或 Gatekeeper 信任。

## 翻译自动检测短文本误报修复（2026-11-07）

问题：语言包已安装时，原文语言为“自动检测”的短文本仍提示“无法检查系统语言资源，请稍后重试”。

根因与本机探针（只读系统 Translation 状态）：

- `LanguageAvailability.status(from: en, to: zh-Hans)` 返回 `installed`，说明语言包本身正常。
- `LanguageAvailability.status(for: "Hello", to: zh-Hans)` 抛出 `TranslationError(... cause: unableToIdentifyLanguage ...)`；短文本、纯数字、符号或网址也可能触发。旧代码把所有检查异常统一映射成资源检查失败，掩盖了真实原因。

修复：

- 新增 `TranslationLanguageDetector.detectOrInfer`：NaturalLanguage 置信度不足时，按日文假名、韩文、汉字、西里尔、阿拉伯、天城文、泰文和拉丁字母做保守书写系统回退。
- `TranslationWork.resolvedSource` 把推断出的明确源语言用于可用性检查和系统 `translationTask`，不再让系统在短文本上重新猜测。
- 真正无法解析的文本不再显示语言包错误，改为提示“无法识别原文语言，请选择明确的原文语言后重试”；资源缺失页也可对已解析的自动检测语言直接准备语言包。
- 同步更新[翻译模块](modules/translation.md)与[已知限制](known-errors.md)。

命令与结果（本地开发机，macOS Apple Silicon；Swift 测试在沙箱内运行）：

- `scripts/swift-local.sh build`：退出码 0，Build complete。
- `scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests --filter 'TranslationControllerTests|TranslationDetectionTests|TranslationLanguagePackTests|TranslationFlowTests'`：退出码 0，24 个测试、4 个 suite 通过；包含短文本推断、明确源语言传递和无法识别提示回归。
- `scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests`：退出码 1。357 个测试、72 个 suite；330 个通过、20 个跳过、7 个失败（12 个 issue）。失败仍集中在 `Clipboard Private Pasteboard`（8 issue）、`Clipboard Capture Controls`（3 issue）、`Clipboard Plain Text`（1 issue），均为沙箱阻止真实系统剪贴板/pasteboard 写入。
- `python3 -m unittest discover -s Tests/TrayletToolingTests`：退出码 0，40 个测试全部通过。

打包与冒烟（`scripts/build-from-source.sh`）：

- 产出 `build/source/Traylet.app`；`codesign --verify --deep --strict` 通过，包内元数据为 `0.1.0` / build `2` / `0.1.0-beta.2`。
- ZIP `build/Traylet-local-smoke.zip`（4,786,202 bytes），SHA-256 `fd900f82098fdcaef2401d1099da811192227dc67ef373cf7f17d496834d138b`。
- `scripts/smoke-package.sh build/Traylet-local-smoke.zip`：沙箱外退出码 0，完成解包、严格验签、版本核对和包内二进制实际启动，输出 "Synthetic native evidence completed" / "Smoke test passed"。

边界：书写系统回退是启发式，不能保证短文本的语言判断正确；纯数字、符号或极短歧义文本仍需用户明确选择源语言。本机探针只验证系统可用性 API，未验证真实 `TranslationSession.translate` 对短文本的输出质量、系统确认 UI 或前台交互；这些仍需按[验收清单](acceptance.md)实机确认。该包为 ad-hoc 签名、无公证票据，不构成 Developer ID 签名、Apple 公证或 Gatekeeper 信任。

## 翻译快捷键选文本预填（2026-11-07）

产品改动：

- 输入翻译快捷键读取当前前台焦点元素的显式选区；读取成功时翻译窗口直接以选中文本预填原文。辅助功能未授权、焦点不在可读文本元素或应用不提供选区时，窗口照常打开并使用原有输入。
- 选区读取优先使用 `AXSelectedText`；部分应用只暴露 `AXSelectedTextRange` 时，通过 `AXStringForRange` 只读取所选范围。读取前后都会核对焦点元素、角色与安全输入框状态，并保持 20,000 字符上限。
- 同步更新[翻译模块](modules/translation.md)、[数据与隐私](privacy.md)、[MVP 范围](../product/mvp.md)和[验收清单](acceptance.md)。

命令与结果（本地开发机，macOS Apple Silicon；Swift 测试在沙箱内运行）：

- `scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests --filter 'SelectedTextSafetyTests|TranslationControllerTests'`：退出码 0，19 个测试、2 个 suite 通过；覆盖参数化选区回退、焦点/安全框保护以及预填后清空旧译文。
- `scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests`：退出码 1。359 个测试、72 个 suite；332 个通过、20 个跳过、7 个失败（12 个 issue）。
  - 失败仍集中在 `Clipboard Private Pasteboard`（8 issue）、`Clipboard Capture Controls`（3 issue）、`Clipboard Plain Text`（1 issue），均为沙箱阻止真实系统剪贴板/pasteboard 写入，与本轮选区改动无关。
  - 排除：`EditingColorWellTests`（按命令显式跳过）。
- `python3 -m unittest discover -s Tests/TrayletToolingTests`：退出码 0，40 个测试全部通过。

打包与冒烟（`scripts/build-from-source.sh`）：

- 产出 `build/source/Traylet.app`；`codesign --verify --deep --strict` 通过，包内元数据为 `0.1.0` / build `2` / `0.1.0-beta.2`。
- ZIP `build/Traylet-local-smoke.zip`（4,790,365 bytes），SHA-256 `7f3179e4c75c81278cd952fbff6fa4fbe7e4e8d26e25a2b08e5feedfc37f9931`。
- `scripts/smoke-package.sh build/Traylet-local-smoke.zip`：沙箱外退出码 0，完成解包、严格验签、版本核对和包内二进制实际启动，输出 "Synthetic native evidence completed" / "Smoke test passed"。

边界：选区测试使用注入的 AX 焦点快照，只证明读取、回退和保护逻辑；未验证真实前台应用选区、辅助功能授权、全局快捷键、安全输入框或系统焦点变化。真实路径仍需按[验收清单](acceptance.md)实机确认。该包为 ad-hoc 签名、无公证票据，不构成 Developer ID 签名、Apple 公证或 Gatekeeper 信任。

## 翻译选文本预填的前台焦点回退（2026-11-07）

问题与修复：

- 反馈现象：在其他应用用鼠标选中文本后按输入翻译快捷键 `⌃⌥R`，翻译窗口打开但原文框为空。原有实现只查询 system-wide `AXFocusedUIElement`；该查询在部分系统/应用组合上不返回元素，导致读取直接结束。
- 焦点查询改为三级顺序：前台应用自身的 `AXFocusedUIElement` → 前台应用焦点窗口上的 `AXFocusedUIElement` → system-wide `AXFocusedUIElement`。仍校验元素 pid 与前台应用一致，并在读取前后核对焦点未变化。
- AX 消息超时由 0.3 秒提高到 0.5 秒；`AXSelectedText` 与 `AXStringForRange` 的返回值同时接受 `String` 和 `NSAttributedString`（取 `.string`）。
- 安全约束不变：拒绝 `AXSecureTextField`、只读显式选区、20,000 字符上限。同步更新[翻译模块](modules/translation.md)。

命令与结果（本地开发机，macOS Apple Silicon；Swift 测试在沙箱内运行）：

- `scripts/swift-local.sh build`：退出码 0。
- `scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests --filter 'SelectedTextSafetyTests|TranslationControllerTests'`：退出码 0，20 个测试、2 个 suite 通过；新增 `NSAttributedString`/普通字符串/不支持值的归一化用例。
- `scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests`：退出码 1。356 个测试、72 个 suite；329 个通过、20 个跳过、7 个测试失败（10 个参数用例、12 个 issue）。
  - 失败仍集中在 `Clipboard Capture Controls`（2 个测试、3 issue）、`Clipboard Private Pasteboard`（4 个测试、8 issue）、`Clipboard Plain Text`（1 个测试、1 issue），均为沙箱阻止真实系统剪贴板/pasteboard 写入，与本轮选区改动无关。
  - 排除：`EditingColorWellTests`（按命令显式跳过）。
- `python3 -m unittest discover -s Tests/TrayletToolingTests`：退出码 0，40 个测试全部通过。

打包与冒烟（`scripts/build-from-source.sh`）：

- 产出 `build/source/Traylet.app`；`codesign --verify --deep --strict` 通过，包内元数据为 `0.1.0` / build `2` / `0.1.0-beta.2`。
- ZIP `build/Traylet-local-smoke.zip`（4,777,055 bytes），SHA-256 `65bfeb19fd44001a53ebea19d05e6d5ad1e4131a0b9975df3c295a646fa84377`。
- `scripts/smoke-package.sh build/Traylet-local-smoke.zip`：沙箱外退出码 0，完成解包、严格验签、版本核对和包内二进制实际启动，输出 "Synthetic native evidence completed" / "Smoke test passed"。

边界：测试使用注入的 AX 焦点快照，只证明三级焦点查询、选区读取、回退与安全保护逻辑；本轮未在真实前台应用（如 TextEdit/Safari/Chrome）验证鼠标选区预填、辅助功能授权状态或安全输入框。system-wide 查询失败的具体触发条件未独立探针确认，因此该修复是提高兼容性的回退策略，不等于系统级根因已证实。后续实查表明本轮不是完整修复：本机没有 Traylet 的辅助功能授权条目，见下一节。该包为 ad-hoc 签名、无公证票据，不构成 Developer ID 签名、Apple 公证或 Gatekeeper 信任。

## 输入翻译选区读取的辅助功能授权（2026-11-07）

问题与实查：

- 反馈现象：在上一轮三级焦点查询回退之后，其他应用鼠标选中文本再按 `⌃⌥R`，翻译窗口仍不能预填。
- 本机实查：macOS 26 的“系统设置 › 隐私与安全性 › 设备控制和数据访问”（辅助功能授权入口）列表中没有任何 Traylet 条目，说明该应用从未获得读取其他应用选区的权限；`AXIsProcessTrusted()` 为 false 时读取在焦点查询前就返回无选区。
- 签名实查：本地构建为 ad-hoc 签名，`codesign -dr -` 输出只有 `designated => cdhash H"…"`。每次重新构建都会改变 cdhash，既有授权随之失效，需要重新授权。

修复：

- 输入翻译快捷键在无授权时每次启动触发一次系统辅助功能授权提示；翻译窗口原文区显示“无法读取选中文本”的原因和“打开系统设置”按钮。
- 翻译设置新增“辅助功能”分区，显示已授权/未授权状态，并提供请求权限或打开系统设置的入口；应用重新激活时刷新状态。
- 不修改 TCC 记录、不绕过授权，也不在未授权时改用模拟复制读取选区。三级焦点查询与安全保护保持不变。

命令与结果（本地开发机，macOS Apple Silicon；Swift 测试在沙箱内运行）：

- `scripts/swift-local.sh build`：退出码 0。
- `scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests --filter 'SelectedTextSafetyTests|TranslationControllerTests|SettingsSurfaceTests|LocalizationTests'`：退出码 0，33 个测试、6 个 suite 通过。
- `scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests`：退出码 1。357 个测试、72 个 suite；330 个通过、20 个跳过、7 个测试失败（12 个 issue）。
  - 失败仍集中在 `Clipboard Capture Controls`（2 个测试、3 issue）、`Clipboard Private Pasteboard`（4 个测试、8 issue）、`Clipboard Plain Text`（1 个测试、1 issue），均为沙箱阻止真实系统剪贴板/pasteboard 写入，与本轮改动无关。
  - 排除：`EditingColorWellTests`（按命令显式跳过）。
- `python3 -m unittest discover -s Tests/TrayletToolingTests`：退出码 0，40 个测试全部通过。

打包与冒烟（`scripts/build-from-source.sh`）：

- 产出 `build/source/Traylet.app`；`codesign --verify --deep --strict` 通过，包内元数据为 `0.1.0` / build `2` / `0.1.0-beta.2`。
- ZIP `build/Traylet-local-smoke.zip`（4,797,420 bytes），SHA-256 `8671edeaf52433571ea8c983bda0b393a1ca6849ea704b5048390a16728ef469`。
- `scripts/smoke-package.sh build/Traylet-local-smoke.zip`：沙箱外退出码 0，完成解包、严格验签、版本核对和包内二进制实际启动，输出 "Synthetic native evidence completed" / "Smoke test passed"。

边界：辅助功能授权必须由用户在系统提示或系统设置中确认，自动化和测试不能代为授权，因此本轮未完成“授权后真实前台选区预填”的实机验收，也未通过真实 UI 观察授权提示与提示条。ad-hoc 构建重新签名后可能需要再次授权。真实路径仍需按[验收清单](acceptance.md)实机确认。该包为 ad-hoc 签名、无公证票据，不构成 Developer ID 签名、Apple 公证或 Gatekeeper 信任。

## 切换翻译引擎直接发送（2026-11-07）

产品改动：

- 点击另一个引擎图标视为用户已经明确选择并提交：直接以当前原文发送，不再打开“发送目标与正文”确认 sheet。
- “翻译”按钮首次向某引擎发送时仍展示目标与正文并等待确认；同一窗口内该引擎确认过一次后，后续发送直接执行。
- 实现通过 `startSubmission(skipPreview:)` / `submit(skipPreview:)` 传递本次直发意图；预览请求在同一主线程回合内设置并清除，不进入可见 sheet。
- 同步更新[翻译模块](modules/translation.md)与[数据与隐私](privacy.md)的外部发送确认说明。

命令与结果（本地开发机，macOS Apple Silicon；Swift 测试在沙箱内运行）：

- `scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests --filter 'TranslationEnginesTests|TranslationControllerTests|ClipboardTranslationBridgeTests|TranslationDeepLTests'`：退出码 0，43 个测试、6 个 suite 通过。
- `scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests`：退出码 1。357 个测试、72 个 suite；330 个通过、20 个跳过、7 个测试失败（12 个 issue）。
  - 失败仍全部来自剪贴板系统 pasteboard 写入受沙箱限制，与本轮翻译改动无关。
  - 排除：`EditingColorWellTests`（按命令显式跳过）。
- `python3 -m unittest discover -s Tests/TrayletToolingTests`：退出码 0，40 个测试全部通过。

打包与冒烟（`scripts/build-from-source.sh`）：

- 产出 `build/source/Traylet.app`；`codesign --verify --deep --strict` 通过，包内元数据为 `0.1.0` / build `2` / `0.1.0-beta.2`。
- ZIP `build/Traylet-local-smoke.zip`（4,797,923 bytes），SHA-256 `246708ffcecb6a30503f5af36af2c4a4eafd10161e327047fc3adafbc0c4d2c5`。
- `scripts/smoke-package.sh build/Traylet-local-smoke.zip`：沙箱外退出码 0，完成解包、严格验签、版本核对和包内二进制实际启动，输出 "Synthetic native evidence completed" / "Smoke test passed"。

边界：测试使用注入的翻译客户端，只证明状态机不再进入确认态并直接调用所选引擎；未验证真实前台点击、真实网络请求、服务失败时的界面表现或确认 sheet 的视觉状态。真实引擎发送仍需按[验收清单](acceptance.md)实机确认。该包为 ad-hoc 签名、无公证票据，不构成 Developer ID 签名、Apple 公证或 Gatekeeper 信任。

## 废弃链路清理与空闲轮询优化（2026-11-07）

代码清理（不改变用户可见功能）：

- 移除设置页已不再提供的“固定短文测试”预览链路：`TranslationConfiguration` 的 `request`、`confirm`、`startConfirmed`、`preview`、`status`、`localizedStatus` 和 `.modelTest` 动作，以及对应本地化文本和 5 个过时测试。设置页的“获取模型”“测试连接”和 DeepL 测试仍直接执行，并在按钮上显示进行中、成功或失败；翻译窗口通过“翻译”按钮首次发送的确认预览保持不变（后续引擎图标切换改为直发，见上一节）。
- 移除无调用的编辑辅助方法 `EditingDocument.selectedNumber`、`EditingDocument.deleteSelectedNumber` 和 `EditingControls.fontFormatter`；编号测试改用现有的 `selectedMark?.number` 与 `deleteSelectedMark()`。
- 同步更新[剪贴板模块](modules/clipboard.md)中的空闲轮询约束。

性能优化：

- 剪贴板空闲轮询不再在未实际裁剪条目时重复核对当前选区；只有条目被移除或搜索/收藏过滤变化时才重新核对。收藏加载完成后仍显式核对一次选区，保持原有选择清理语义。
- 参考性能测试（debug、合成夹具、Apple Silicon 本机）`clipboard.refresh.idle100` 的 p50：
  - 100 条：5.582 / 5.558 ms → 4.284 / 4.404 ms（约 -21% 至 -23%）。
  - 500 条：26.188 / 26.076 ms → 21.024 / 21.308 ms（约 -18% 至 -20%）。
  - 1000 条：52.103 / 51.998 ms → 41.813 / 42.713 ms（约 -18% 至 -20%）。
  - p95 同步下降约 18% 至 22%；其他搜索、刷新和编辑指标在运行噪声范围内，未发现一致回退。

命令与结果（本地开发机，macOS Apple Silicon；Swift 测试在沙箱内运行）：

- `scripts/swift-local.sh build`：退出码 0，Build complete。
- `scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests`：退出码 1。355 个测试、72 个 suite；328 个通过、20 个跳过、7 个失败（12 个 issue）。
  - 失败仍集中在 `Clipboard Private Pasteboard`（8 issue）、`Clipboard Capture Controls`（3 issue）、`Clipboard Plain Text`（1 issue），均为沙箱阻止真实系统剪贴板/pasteboard 写入，与本轮清理和性能改动无关。
  - 删除 5 个随固定短文测试链路移除的过时测试，并新增 1 个“过期选中项清除选择”回归测试，净减少 4 个。
  - 排除：`EditingColorWellTests`（按命令显式跳过）。
- `python3 -m unittest discover -s Tests/TrayletToolingTests`：退出码 0，40 个测试全部通过。
- `TRAYLET_REFERENCE_PERF=1 TRAYLET_REFERENCE_PERF_DIR=/tmp/traylet-perf-final2 scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests --filter ReferencePerformanceTests`：退出码 0，1 个测试、1 个 suite 通过。

打包与冒烟（`scripts/build-from-source.sh`）：

- 产出 `build/source/Traylet.app`；`codesign --verify --deep --strict` 通过，包内元数据为 `0.1.0` / build `2` / `0.1.0-beta.2`。
- ZIP `build/Traylet-local-smoke.zip`（4,776,561 bytes），SHA-256 `c519983c2014f725ae4eda1b9cab0b57bbb0a74f3c11960d49d9f900fb878427`。
- `scripts/smoke-package.sh build/Traylet-local-smoke.zip`：沙箱外退出码 0，完成解包、严格验签、版本核对和包内二进制实际启动，输出 "Synthetic native evidence completed" / "Smoke test passed"。

边界：参考性能是单机合成基线，不构成绝对阈值或真实 UI/磁盘/剪贴板轮询的时延承诺；清理只移除无生产调用路径，不替代真实前台交互、系统权限或系统剪贴板验收。该包为 ad-hoc 签名、无公证票据，不构成 Developer ID 签名、Apple 公证或 Gatekeeper 信任。

## 执行命令

```sh
scripts/swift-local.sh build
scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests
python3 -m unittest discover -s Tests/TrayletToolingTests
scripts/package-local.sh
```

发布候选还需同包取证和 `scripts/deliver-local.sh` 所要求的证据检查。打包单独通过不能放行。

## 结果口径

记录测试总数以及通过、跳过、排除、失败；不要把空 AX 树跳过或被排除的系统 UI 测试列为通过。记录每次命令退出码、SDK/OS、源码/包哈希和日志路径。测试失败与环境阻塞（例如缺少系统资源或授权）分开描述。

原生合成图只证明生成它们的组件/输入和断言，不证明真实前台视觉、WindowServer 材质、物理键盘、权限或外部服务。直接执行和 LaunchServices 启动的权限状态分开记录。

## 既有证据

`0.3.10 / build 26` 的体验交付记录属于重整前的历史版本，留在维护者本机档案中，不纳入公开仓库。该记录不能认证 Beta 1 或 Beta 2，也不能填入当前版本的验收清单。
