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
- Swift 测试 `scripts/swift-local.sh test --no-parallel --skip EditingColorWellTests`：350 个测试、72 个 suite 全部通过。Python 工具测试 38 个全部通过，其中新增 `test_app_assembly.py` 覆盖资源封印回归。
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
