# 合成取证模块

**实现目录：** `Sources/TrayletApp/Evidence/`  
**测试目录：** `Tests/TrayletAppTests/Evidence/`

唯一应用证据入口为 `--v2-native-evidence <absolute-directory>`。它使用合成内容、fake 服务、内存偏好和临时归档，不启动生产采集或发送真实用户内容。

报告 `syntheticOffscreen` 只表示指定的原生组件/输入证据流程完成；不代表真实 WindowServer 外观、权限、服务质量、前台交互或 Beta 放行。候选包的 manifest 必须关联实际编译源、候选二进制与同包证据。
