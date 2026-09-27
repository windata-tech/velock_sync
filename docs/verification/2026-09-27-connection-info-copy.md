# 连接说明的内容口径（2026-09-27）

## 用户反馈

现场截图（WebDAV 连接，`新建连接` → 更多操作 → 连接说明）：用户原话
**「我感觉这个说明有点不对呢」**。原内容：

```
功能说明  条件创建 / 范围下载 / 安全存储密码
注意事项  断点续传取决于服务器能力；当前适配器会安全重试不可变对象。
```

## 逐条核对（对着适配器代码）

| 原文 | 结论 |
| --- | --- |
| 条件创建 | 是适配器内部机制（`If-None-Match` 不可信 → 先写私有临时集合再原子 MOVE），但对用户是黑话，看不出「不会覆盖你的文件」 |
| 范围下载 | `RemoteCapabilities.supportsRangeDownload` 只被适配器自己用于分片读取；**同步引擎从不按范围读**，对用户不是功能 |
| 安全存储密码 | 事实成立（`SecureCredentialStore` → Keychain/Keystore），但它是 **App 的存储方式**，不是连接类型的功能 |
| 断点续传取决于服务器能力 | **错**：WebDAV 适配器 `supportsResumableUpload: false`，引擎也没有持久化任何上传会话（`providerCheckpoint` 无人写入）→ 大文件中断后必然整份重传，与服务器能力无关 |
| 会安全重试不可变对象 | 内部黑话；实际情况是对象只创建不覆盖，重试不可能覆盖已有内容 |

OAuth 分支同样有问题：`可恢复上传`（引擎不保存上传会话，中断后重建会话从头传）、`回收站`
（`supportsTrash: true` 只描述云盘，App 的 `delete` 走 `files.delete` 永久删除，从不使用回收站）、
`范围下载` 同上。另外 `test/l10n/sync_english_pages_test.dart` 里有一条**显式记录的技术债**：
该文件是纯中文常量，英文界面会显示中文（测试注释写着 “localize provider_capability_summary.dart, then delete this test”）。

## 新口径

`lib/providers/provider_capability_summary.dart` 重写，两条规则写进文档注释：

1. 只描述 App 对这种连接**实际实现**的行为，不描述「服务器也许能做到」的能力，也不把
   App 从未调用的服务端特性（回收站、范围读）写成 Sync 的功能。能力旗标在各适配器的
   `RemoteCapabilities` 里，文案不得超出旗标（WebDAV `supportsResumableUpload: false`，
   所以任何一行都不许暗示续传）。
2. 每个字符串都本地化（`syncText`）；`context` 是 **required-but-nullable**，调用方无法忘记传
   locale。

WebDAV 现在写的是：

- 功能说明：浏览、上传和下载服务里的文件 / 新文件先写临时文件、再原子改名：不会覆盖服务上已有的同名文件
- 注意事项：不支持断点续传：大文件中断后要从头重新上传 / 服务不支持原子改名时会拒绝写入并提示，不会降级成可能覆盖的写入 / 备份要选这个账号真正能写入的文件夹；只读入口和聚合视图都不行
- 登录信息（新行，取代「安全存储密码」这条“功能”）：密码存在系统安全存储里，不写进连接记录、备份或日志

云盘（Google Drive / OneDrive）：浏览器 PKCE 授权（不接触云盘密码）/ 浏览、上传和下载授权范围内的文件 /
大文件按分片上传；限制为该云盘自己的授权范围 + 「上传中断后下一次会重新开始」；
未接入的云盘改说「需要官方的授权组件，当前版本还不能使用」，不再出现 `Token Broker` 之类黑话。

`lib/features/connection/ui/connection_info_sheet.dart` 增加第 5 行「登录信息 / Credentials」，位置在
注意事项之后（保密方式属于 App，不混进“功能”）。

## 验证

- `test/providers/provider_capability_summary_test.dart` 重写为 7 项：WebDAV 的朴素描述、
  **黑话与未使用特性一律不得出现**（条件创建/范围下载/回收站/可恢复上传/Token Broker）、
  **不夸大续传**（直接实例化 `WebDavObjectStore` 断言 `supportsResumableUpload == false`，
  再断言文案与之一致）、云盘各自的授权限制、凭据不被当成连接功能、未接入云盘不承诺任何功能、
  以及英文 locale 下四类连接的每一行都不含中文。
- `test/l10n/sync_english_pages_test.dart`：删掉那条“仍是中文”的例外，改为
  「the connection info sheet paints no Chinese」——英文界面逐 Text/Semantics 扫描无中文。
- `test/features/connection/connection_edit_entry_test.dart`：更新为断言新的功能说明、注意事项与登录信息行。
- `test/features/connection/connection_loading_test.dart`：目录页打开说明后断言的旧注意事项文案改为「不支持断点续传…」。
- `test/features/connection/connection_oauth_info_test.dart` 不变仍通过（PKCE 保留在功能说明里，
  主连接页仍然不显示这些技术项）。
- `flutter analyze`：No issues found；`flutter test`：1103 项全部通过
  （日志 `/tmp/velock-analyze-conn-final2.txt`、`/tmp/velock-tests-conn-final2.txt`）。
- 真实 CJK 字体渲染证据 `ui_test_results/connection-info-20260927/`：
  `01-webdav-zh.png`、`02-google-drive-zh.png`、`03-webdav-en.png`
  （widget + 内存 fixture，不是模拟器/真机截图；入口 `test/features/connection/connection_info_visual_qa_test.dart`，
  未设环境变量时只断言不写文件）。

## 边界

- 只改文案与其本地化，没有改任何适配器行为、能力旗标或连接流程；说明仍然只读、不探测服务器。
- 「不支持断点续传」是当前实现的事实，不是永久承诺：将来若真做会话续传（需要持久化
  `providerCheckpoint` 并在恢复时校验），这行文案和对应测试必须一起更新。
