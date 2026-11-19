# 软件权限授权设置功能

本文是 Traylet「权限授权设置」功能的产品设计（PRD），范围是 macOS **系统权限**（TCC 授权），不是商业授权/激活码。目标：把散落的系统权限集中到一个设置分区，可查看/请求/跳转，并在升级导致权限失效时主动引导用户一键重新授权。

## 背景与问题

Traylet 目前用到的系统权限及现状：

| 权限 | macOS 名称 | 用途 | 必需性 | 现有展示位置 | 检测 API |
| --- | --- | --- | --- | --- | --- |
| 屏幕录制 | Screen Recording | 区域/整屏截图 | 必需 | 首次欢迎窗 | `CGPreflightScreenCaptureAccess()` |
| 辅助功能 | Accessibility | 输入翻译快捷键读取其他应用选中文本 | 可选 | 欢迎窗 + 翻译设置「辅助功能」区 | `AXIsProcessTrusted()` |
| 登录项 | Login Items | 登录时启动 | 可选 | 通用设置 | `SMAppService.mainApp.status` |

「升级后需要重新授权」的根因：macOS 的 TCC 授权记录与应用的代码签名身份绑定。本地/预览构建为 ad-hoc 签名，每次重建 `cdhash` 变化，系统将其视为另一个应用，旧授权随之失效。正式版使用 Developer ID 签名 + 公证时，签名身份（Team ID + Bundle ID）跨版本稳定，权限可跨升级保留。

本功能做两件事：

1. 把屏幕录制、辅助功能集中到一个「权限」设置分区，提供状态查看、请求与系统设置跳转。
2. 检测「曾授权、升级后已失效」，主动以一次性轻量弹窗引导用户重新授权，避免截图/翻译静默失败。

## 决策记录

| # | 决策点 | 结论 |
| --- | --- | --- |
| 1 | 登录项归属 | 改归「权限」分区；屏幕录制、辅助功能、登录项三类系统授权统一一处管理 |
| 2 | 失效引导形态 | 仅当确实失效时弹一次轻量弹窗，复用欢迎窗权限行组件 |
| 3 | 签名方式 | 两种都兼容：正式版 Developer ID 签名（升级权限保持，根治）；ad-hoc 预览版（升级后需重新授权，检测 + 引导兜底） |

## 权限清单（最终范围）

权限分区统一管理三类系统授权：

- **屏幕录制**：必需，供区域/整屏截图。
- **辅助功能**（可选）：供输入翻译快捷键读取其他应用的选中文本。
- **登录项**（可选）：登录时启动；由 `SMAppService.mainApp.status` 检测，设置页提供开关。

## 信息架构与交互

设置侧栏顺序：通用 / 快捷键 / 翻译 / 剪贴板 / **权限** / 关于（在 `V2SettingsSection` 增 `case permissions`，插在 `.clipboard` 与 `.about` 之间）。

### 权限分区

```
权限  Permissions
┌──────────────────────────────────────────────┐
│ 屏幕录制                      已允许 / 未允许  │
│ 截图功能需要（区域/整屏截图）   [请求权限]      │
│                                [打开系统设置]  │
├──────────────────────────────────────────────┤
│ 辅助功能（可选）              已允许 / 未允许  │
│ 输入翻译时带入其他应用的选中文字 [请求权限]    │
│                                [打开系统设置]  │
├──────────────────────────────────────────────┤
│ 登录时启动                          [开关]     │
│ 登录后在菜单栏自动打开 Traylet                 │
└──────────────────────────────────────────────┘
说明：授权变更后回到本页会自动刷新。
```

交互规则：

- 未允许：主按钮「请求权限」触发系统授权弹窗（`CGRequestScreenCaptureAccess()` / `AXIsProcessTrustedWithOptions`），副按钮「打开系统设置」跳 `Privacy_ScreenCapture` / `Privacy_Accessibility`。
- 已允许：只显示「打开系统设置」（供查看/撤销），状态徽标为绿色「已允许」。
- 登录项：提供开关切换 `SMAppService.mainApp.status`；需批准时显示提示，回到本页时刷新。
- 进入分区与 App 重新激活（`NSApplication.didBecomeActiveNotification`）时刷新状态。

### 升级后失效引导（一次性）

触发条件：持久化快照显示「曾允许」，本次启动检测为「未允许」→ 判定失效，弹一次；用户完成或点「稍后」后本次不重复，直到下次再次检测到失效。

```
权限需要重新授权
升级后，Traylet 需要你重新允许以下系统权限。

  ● 屏幕录制          截图功能需要              [允许…]
  ● 辅助功能（可选）  输入翻译时带入选中文字     [允许…]

                                     [稍后]
```

- 只列出实际失效的权限（可能只有一项）。
- 「允许…」复用权限行组件；「稍后」关闭，不阻断使用；截图/翻译入口保留现有「前往权限」失败兜底。
- 区分「从未授权」（走首次欢迎流程）与「曾授权后丢失」（走本弹窗），不误报全新用户。

## 文案表（中英文）

| 场景 | 中文 | English |
| --- | --- | --- |
| 分区标题 | 权限 | Permissions |
| 权限名 | 屏幕录制 | Screen Recording |
| 用途 | 截图功能需要（区域/整屏截图） | Required for captures (region / full screen) |
| 权限名 | 辅助功能（可选） | Accessibility (optional) |
| 用途 | 输入翻译时带入其他应用的选中文字 | Brings selected text from other apps into Input Translation |
| 权限名 | 登录时启动 | Launch at Login |
| 用途 | 登录后在菜单栏自动打开 Traylet | Open Traylet in the menu bar after login |
| 状态 | 已允许 | Allowed |
| 状态 | 未允许 | Not Allowed |
| 按钮 | 请求权限 | Request Permission |
| 按钮 | 打开系统设置 | Open System Settings |
| 按钮 | 允许… | Allow… |
| 弹窗标题 | 权限需要重新授权 | Permissions need to be re-granted |
| 弹窗正文 | 升级后，Traylet 需要你重新允许以下系统权限。 | After the update, Traylet needs you to allow the following permissions again. |
| 按钮 | 稍后 | Later |
| 页脚 | 授权变更后回到本页会自动刷新。 | Permission changes refresh automatically when you return to this page. |

文案规范：翻译设置旧文案 `已授权/未授权` 建议统一收敛为 `已允许/未允许`，与欢迎窗一致，避免两处措辞漂移。

## 组件与接口拆分（方向建议，非技术决策）

1. **权限状态读取** `V2PermissionStatus`（可观察对象）：暴露 `screenRecordingGranted` / `accessibilityGranted`；提供 `requestScreenRecording()` / `requestAccessibility()` / `openScreenRecordingSettings()` / `openAccessibilitySettings()`；监听 App 激活自动刷新。
2. **权限行视图** `V2PermissionRow`：从 `V2WelcomeView.permissionRow` 抽取为公共组件，供「欢迎窗 / 权限分区 / 失效引导弹窗」三处复用。
3. **快照持久化** `V2PermissionSnapshotStore`：存 `~/Library/Application Support/Traylet/v2/permissions.json`，字段 `schemaVersion`、`lastScreenRecordingGranted`、`lastAccessibilityGranted`；沿用 `V2PreferencesStore` 的防护（大小上限、符号链接拒绝、目录 0700 / 文件 0600）；损坏视为「无快照」走首次流程。
4. **失效检测与引导** `V2PermissionRecovery`（协调层）：启动时对比快照与当前状态，`曾允许 && 现未允许` → 触发一次性弹窗；与 `V2AuthorizationGate` / 首次欢迎流程解耦。

## 验收标准（DoD）

- 权限分区展示屏幕录制、辅助功能、登录时启动三项，状态与系统实际一致，请求/跳转/开关三路可用。
- 旧版已授权 → 覆盖安装新版（ad-hoc 重建签名）→ 首次启动弹出一次性重新授权引导；全新用户不误报。
- 完成授权或点「稍后」后本次运行不再重复弹出；下次再次失效才再弹。
- 欢迎窗与权限分区共用同一权限行组件，文案一致（`已允许/未允许`）。
- 快照文件权限 0600、目录 0700，损坏/缺失时不误报、不清空其他数据。
- 中英文文案齐全（见文案表）。

## 成功指标

1. 升级后权限失效时，100% 被明确引导重新授权（不再静默失败）。
2. 权限分区状态与系统实际一致率 = 100%。
3. 正式版（Developer ID 签名）升级后权限保持率 = 100%。
4. 上线后 4 周内「升级后截图/读取选中文本失效」类工单降为 0。

## 边界与风险

- ad-hoc 重签名导致权限失效是系统行为，代码内无法根治；本功能做到「检测 + 引导」，根治依赖 Developer ID 签名。
- 用户主动撤销权限与升级失效同表现，引导文案保持中性，不指责、不反复弹。
- 快照只存布尔状态，不含任何用户内容；不修改 TCC、不绕过授权，符合[数据与隐私](../development/privacy.md)。
