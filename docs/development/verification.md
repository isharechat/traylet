# 验证记录

## 当前修正版 Beta 状态

- 修正版目标为 `0.1.0-beta.2` / build `2`；对应值已写入 `VERSION` 与 `BUILD_NUMBER`，CI tag 仍须与 `VERSION` 完全相等。
- 对已发布的 Beta 1 ZIP 做了 SHA-256 检查，结果通过；解包后 `codesign --verify --deep --strict` 报告 `code has no resources but signature indicates they must be present`。原因是组装 `.app` 后没有重新签整个 bundle，macOS 因此提示应用已损坏。
- Beta 1 Release 已转为草稿并标注不可用，旧下载资产未删除，以保留追溯证据。
- 已修正 CI 包脚本：完成 Info.plist 和资源组装后签名整个 `.app`，并严格验证资源封印。手动 CI 产物使用 ad-hoc 签名，仅供检查，不受 Gatekeeper 信任。
- 公开 Beta 2 流程已设为失败关闭：需要 Developer ID Application P12 和 App Store Connect API key；签名后提交 Apple 公证、staple 票据、运行 `codesign` 与 `spctl` 验证，全部成功才创建 Release。
- 当前开发机 `security find-identity` 找到 0 个有效签名身份，GitHub 仓库没有配置所需签名/公证 secrets。因此 Beta 2 尚未构建或发布；不能承诺可供下载运行。
- Beta 1 的 CI 编译和 Swift/Python 测试曾通过，但不构成当前 Beta 2 的签名、公证或系统运行验证。真实权限、视觉、安装和应用功能验收仍待完成。

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
