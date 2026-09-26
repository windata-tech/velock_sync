# 目录进入时正文闪烁修复（2026-09-26）

## 根因

Connection把整个正文放在AsyncValue.when内。RemoteFileBrowser.go先发布无数据的loading，因此进入目录会卸载整个CustomScrollView（包括路径、能力卡、网格），替换为居中加载圈，成功再挂载。返回命中父目录缓存时直接发布data，不经过loading，所以用户看到进入闪而返回不闪。

## 修改

- provider明确保留最后可见的FileBrowserState，暴露visibleState，仅在加载期间提供旧画面；成功使用新结果，失败不把旧列表当成新目录。保留generation和配置根目录边界，返回仍可中断等待并拒绝晚到结果。
- 不使用Riverpod标记internal的copyWithPrevious API。加载状态仍正常发布，保留显示数据与请求状态分别表达。
- Connection正文始终为同一个CustomScrollView；路径与能力卡结构稳定。加载时保留旧路径和列表，仅路径旁预留的20px区域显示小型进度提示。完成后切换新路径和内容。
- 等待期间旧项与刷新按钮禁用，provider文件点击入口也拒绝加载中重复操作；返回仍可用。首次加载不显示假的空目录；失败显示错误区、保留能力卡与重试/返回入口。

## 自动测试

新增connection_loading_test.dart由统一worker入口委派，Qwen服务不可用自动回退DeepSeek。worker遵守沙箱限制，格式化受SDK缓存写权限阻挡后立即返回，主模型负责格式化、审查与执行。

6个iOS/Android慢请求widget用例覆盖：加载中的路径/旧列表保留、文件项和能力卡Element身份及屏幕位置不变、重复点击无请求、完成后切换、失败清除旧列表但保留能力卡、返回恢复父目录、首次等待不伪装空目录。provider本机WebDAV用例额外验证visibleState保留且晚到请求不覆盖父目录。

回归范围：test/widgets、test/features、test/appearance、test/providers/webdav、test/sync_profiles、test/dataset_adapters/velock_exchange、test/sync_core/join_approval_applier_test.dart。

结果与产物以项目外目录为准：
`/Users/parcool/AndroidStudioProjects/velock_sync-artifacts/work/folder-loading-20260926/`。

## GUI观察边界

在保留画面的初版构建上，DeepSeek带锁Computer Use只读浏览：`/` → `/USB_HDD_8T` → `/USB_HDD_8T/software` → `/USB_HDD_8T`，未报错、未触发下载或写操作。AX调用约1.7秒后返回，请求已经完成，**不能将这次GUI观察声明为逐帧无闪烁验证**；加载中间态由上述可控慢请求widget测试证明。截图installed-browser.png为加载完成状态。

随后按静态分析要求将Riverpod内部copyWithPrevious替换为显式visibleState，再执行最终测试与完整构建安装。最后一次安装可能回到首页，不将先前GUI停留路径冒称最终停留位置。

没有删除/创建NAS目录，没有备份、恢复、授权或凭据修改；这不是完整同步验收。

最终结果：**423项回归通过**，4个改动Dart文件静态分析 **No issues found**；最终Debug模拟器包构建、安装、启动成功（既有iPhone17 Pro Max / iOS26.5，设备ID `26CC5821-DEF4-47D3-978D-A11D7293AD61`）。
