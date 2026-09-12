# 实现状态

更新日期：2026-09-12

当前产品按两类数据集实现：

1. `velock-managed`：格间数据的零知识远程备份。Sync 只传输格间已经加密和认证的 Exchange artifacts；内容恢复、最近删除和冲突仍由格间本体负责。
2. `selected-folder`：用户选择文件夹的通用双向同步。远端只保存 Generic Vault 加密对象，使用独立 root key、设备签名身份和恢复材料。

## 已完成的产品调整

- 同步首页改为「备份与同步」，明确显示「格间备份」和「文件夹同步」两个区域；
- 新增「新建同步」类别选择页；
- 格间空状态和目标文案改为持续备份优先，换机仅是恢复场景；
- 恢复 selected-folder 数据集、Generic Vault 加解密、安全密钥存储、扫描、批次编译、冲突解决和执行器；
- 前台和后台 Dispatcher 同时注册两类执行器；
- selected-folder Profile 继续使用稳定的 `selected-folder` persisted kind；
- 修复文件 mtime 持久化精度导致的重复变更检测问题；
- 新增 Selected Folder 专用双 iOS Simulator XCUITest，覆盖 WebDAV、目录授权、首次加密上传、恢复包导出、第二设备导入、下载与内容哈希校验。

## 当前剩余工作

- iOS 真机 App Group entitlement、签名构建和格间互操作验证；
- selected-folder 真机 Document Picker / SAF 授权、后台限制和真实 Provider 长流程验证；
- Provider 账号端到端恢复演练、故障注入和发布证据；
- 发布前的 UI 截图回归、动态字体和深色模式验收。
