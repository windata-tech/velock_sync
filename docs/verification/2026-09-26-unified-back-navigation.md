# 统一返回按钮与目录返回（2026-09-26）

## 问题与修复

用户截图为连接详情的远程文件浏览页，而非备份文件夹选择器。旧页头直接调用路由pop，且RemoteFileBrowser的_currentPath进入子目录后未更新，导致canGoBack始终按根目录判断。

- 文件浏览页：按钮与系统返回先回上一级目录；只有配置的连接根目录才退出页面。显示当前路径辅助确认；刷新/重试保留当前路径。
- provider以当前请求路径维护导航，失败或加载中仍可返回；旧请求晚到不覆盖已返回的父目录；父目录缓存命中无需网络；拒绝导航超出配置根目录。
- 备份目录选择器采用同样语义；正在创建目录时继续禁止离开，防止写入结果不确定。底部“使用这个文件夹”仍是明确选择并关闭，不改成上一级。
- 共享AppBackButton：单个左chevron、同一颜色/图标尺寸、至少44px触控区，中文/英文辅助标签，支持禁用。WDAppBar与大小标题/紧凑滚动标题均使用它；不再由系统自动混入带上一页标题或箭杆的返回按钮。
- 替换连接详情、协议选择、新建连接、WebDAV配置及OAuth选目录中的独立返回实现。关闭/取消保留原语义；iOS状态栏的“返回格间”属于系统跨App入口，不修改。

## 分工与验证

通过用户指定的qwen-worker统一入口委派公共按钮和三处简单页面替换，Qwen服务不可用后自动回退DeepSeek。主模型审查差异、实现目录状态与路由行为、补齐滚动标题栏并执行测试。worker沙箱内尝试运行Flutter测试受环境限制并持续排查后，由主模型停止该worker、接管验证，没有扩大worker权限。

测试：

```sh
flutter test --no-pub --reporter expanded \
  test/widgets test/features test/appearance test/providers/webdav \
  test/sync_profiles test/dataset_adapters/velock_exchange \
  test/sync_core/join_approval_applier_test.dart
```

**417项通过**。覆盖共享按钮根页/子页、显式回调与禁用、PopScope、中文英文、iOS/Android和滚动大小标题；实际连接页点击目录与返回/系统返回；本机假WebDAV验证provider当前路径、缓存、失败、晚到请求、根边界；备份选择器创建保护和取消无写入回归。

首轮共享按钮测试错误要求Material工具栏外框也必须恰好44px（实际56px），已按“至少44px触控区 + 统一20px图标”的真实要求修正，不改变平台工具栏高度。

改动范围静态分析 **No issues found**。记录位于项目外：
`/Users/parcool/AndroidStudioProjects/velock_sync-artifacts/work/unified-back-20260926/`。

## 验证边界

这次只调整界面导航与只读目录浏览，不删除/新建NAS目录，不改连接账号/凭据，不批准格间授权，不执行上传或恢复。原NAS并发401和空远端完整迁移限制仍保留，不能用导航测试宣称同步全流程通过。

## 安装与实际界面验收

Debug模拟器包构建、安装及启动成功，使用既有 iPhone 17 Pro Max / iOS26.5（`26CC5821-DEF4-47D3-978D-A11D7293AD61`），未擦除/新建模拟器。

DeepSeek通过带锁Computer Use执行10次只读导航，主模型核对截图：

1. 进入现有“新建连接”的连接根目录 `/`。
2. 进入 `/USB_HDD_8T`，再进入 `/USB_HDD_8T/velock-sync`。
3. 点击页头返回只回到 `/USB_HDD_8T`；再次返回到 `/`；根目录再返回才退出至“连接”列表。
4. 普通“连接”页也使用统一chevron；最后重新进入连接浏览页并停在 `/` 供用户继续操作。

这次浏览未出现401/授权提示；不据此推断此前并发上传401已修复。截图在上述外部产物目录的 `webdav-velock-sync-root.png` 与 `webdav-connection-root.png`。旧目录仍保留，未发起任何数据创建/删除/备份恢复操作。
