# Traylet 文档中心

欢迎查阅 Traylet 文档。这里分为面向用户的**应用文档**与面向贡献者的**开发文档**；早期历史记录保存在只读的[历史文档归档](archive/README.md)中。

## 应用文档（用户指南）

| 文档 | 内容 |
| --- | --- |
| [快速上手](guide/getting-started.md) | 系统要求、安装方式、菜单栏入口、默认快捷键与设置概览 |
| [截图与标注编辑](guide/capture-and-editing.md) | 区域/整屏截图、选区微调、标注工具、PNG 输出与悬浮置顶 |
| [文字与截图翻译](guide/translation.md) | 输入翻译选区读取、截图 OCR、Apple 系统翻译与外部服务 |
| [剪贴板历史](guide/clipboard.md) | 整段运行记录机制、筛选搜索、本机归档与排除应用配置 |
| [系统权限说明](guide/permissions.md) | 屏幕录制、辅助功能、登录项授权与升级重新授权说明 |

## 开发与工程文档

| 文档 | 内容 |
| --- | --- |
| [架构与模块](development/architecture.md) | 代码目录结构、模块边界与共享接口约定 |
| [模块说明](development/modules/README.md) | 截图编辑、翻译、剪贴板、设置、本地化与取证模块职责 |
| [数据与隐私](development/privacy.md) | 本机处理、剪贴板归档、外部发送确认与系统权限边界 |
| [原生界面与设计规范](development/design.md) | SwiftUI / AppKit 原生交互与视觉约束 |
| [构建、打包与发布](development/packaging.md) | `0.1.0-beta.6` / build `6`、源码构建、签名公证与本地交付 |
| [开发与验证](development/verification.md) | 构建与测试命令、证据分级与当前验证状态 |
| [发布验收清单](development/acceptance.md) | 发布前必须核对的功能回归、系统集成与签名放行项 |
| [已知限制](development/known-errors.md) | 当前已知限制、已确认缺陷与防复发规则 |
| [词汇表](development/glossary.md) | 项目领域统一用词 |

## 开始开发

贡献代码前请先阅读[项目开发指引](../AGENTS.md)与[架构与模块](development/architecture.md)。涉及采集、持久化、权限或外部请求时请阅读[数据与隐私](development/privacy.md)，涉及构建与发布时请阅读[构建、打包与发布](development/packaging.md)。
