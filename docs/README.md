# Traylet 文档

当前资料以首个 MVP 及修正版 Beta 为范围。产品目标见[首个 MVP](product/mvp.md)；开发、验证和打包入口见下表。旧阶段交接与测试日志保存在[历史文档归档](archive/README.md)，只用于追溯，不代表当前状态。

| 文档 | 用途 |
| --- | --- |
| [MVP 产品范围](product/mvp.md) | 首个 Beta 的用户、核心任务、包含与排除范围 |
| [产品地图](development/map.md) | 产品边界、当前导航和状态口径 |
| [架构与模块](development/architecture.md) | 代码分层、数据流和模块职责 |
| [数据与隐私](development/privacy.md) | 剪贴板同意、数据保存、外部发送和权限 |
| [设计约束](development/design.md) | 原生视觉与交互约束 |
| [开发与验证](development/verification.md) | 本地构建、测试命令、证据分级和当前验证状态 |
| [Beta 打包](development/packaging.md) | `0.1.0-beta.2` / build `2`、本地签名与 GitHub Actions |
| [验收清单](development/acceptance.md) | Beta 前必须检查的行为与系统集成 |
| [已知限制](development/known-errors.md) | 当前已知限制与明确未验收项 |
| [词汇表](development/glossary.md) | 产品领域的统一用词 |

## 开始开发

先读[项目指引](../AGENTS.md)和[MVP 产品范围](product/mvp.md)。功能实现时读对应[模块文档](development/modules/)，修改权限或剪贴板时读[数据与隐私](development/privacy.md)，打包时读[Beta 打包](development/packaging.md)。
