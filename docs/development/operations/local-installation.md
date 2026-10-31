# 本地安装

本地安装会替换用户唯一启动位置 `/Applications/Traylet.app`，与构建候选、签名、验证和公开发布分别处理。首个 Beta 当前没有安装。

## 交付流程

完整受保护流程：

```sh
scripts/deliver-local.sh
```

脚本先验证候选与同包证据，再调用安装器。候选或运行状态未知时安全暂存；不会强退应用、清除 quarantine、修改 TCC/Gatekeeper、变更系统信任或自动降级较新版本。

单独运行 `scripts/package-local.sh` 只会生成本机签名候选，不会安装，也不代表通过 `docs/development/acceptance.md`。

## 首个 Beta

`0.1.0-beta.1` / build `1` 低于历史 `0.3.10` 体验包。安装器的版本保护可能拒绝把它覆盖到更高版本上。该保护不应通过改 Bundle ID、清理用户安装或绕过版本比较规避。

首个 Beta 的构建状态、签名与安装结果见[验证记录](../verification.md)。安装之前先完成 Beta 验收；本次文档/版本配置更新未安装该版本。
