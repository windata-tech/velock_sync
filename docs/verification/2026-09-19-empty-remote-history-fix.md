# 空远端历史缺失：误报修复与边界

## 已复现的根因

Velock 发布回执后，Sync 删除本地已领取传输包。源业务数据库保留变更记录，但不是历史 envelope/operations 的原始字节归档；重新 compile 会生成随机 nonce 和新签名，不能冒充同一不可变批次。

旧源接全新空 WebDAV，仅上传当前 Ready 批次。进度检查点不含业务记录，不能恢复缺失历史。此前 runner 仍将运行记录标为 completed，这是本次已修复的危险误报。

## 已实施的产品修复（Apple App Group 路径）

- 新增可选 `RemoteHistoryValidatingDatasetAdapter`，runner 在上传后、发布检查点/恢复游标/GC/标记完成之前强制验证。异常不经过“检查点 best-effort”吞错分支。
- Apple Velock adapter 以本次已发布最大序号及**本地验签后的**生产者进度作为边界，检查远端该生产者 commit 序号连续性。
- 缺失、重复、异常分页/超限均失败，稳定错误码 `remote.velock_history_incomplete`；记录 `failed / userActionRequired / retryable=false`。
- 中英文提示明确保留旧备份、重新连接完整旧目录，不建议删除数据或盲目重置。
- 检查仅分页读取 commit 名称：每页1000，上限1000页/100000条；零边界无远端IO。不按批次逐个HEAD，更不下载文件和相册正文，因此不增加一次全量传输。

## 已验证

- 相关 Flutter 回归160项通过（含新增历史检查19项及真实签名checkpoint/runner回归）。
- iOS 模拟器构建成功；源演示设备 `history-reject-01` XCTest通过，UI阶段24秒、含安装总39秒。
- 只读检查模拟器实际 `state.db`：最新运行 `failed`，错误码 `remote.velock_history_incomplete`，不再写completed。
- 教程离线13项通过；未降低六类业务和原图/正文验收门禁。

## 必须明确的未完成范围

**这不是自动全量迁移/补传的完成报告。**

- 历史原始包已经被删除时，仅凭 Sync 的进度和源业务变更记录不能安全原样重传。需要完整旧远端/原包归档，或者另行实现可信 Velock 生成、验证和恢复完整快照的协议。
- 当前检查是该生产者 commit 名称连续性的保守门禁，不是所有生产者的数据、签名、业务正文和blob完整性证明。已有远端仅保留空壳commit等情况仍需完整恢复验收。
- 合法GC造成的历史缺口在没有独立完整快照证明时也会被保守拒绝；不伪称支持从此类残缺历史恢复新设备。
- Android目前不提供同样的本地签名进度checkpoint能力，本次未声称已覆盖Android历史迁移。
- 新版中英文完整原片、新设备六类恢复及自动补传仍未完成；旧失败原片不交付。

## 后续真正补传的实现约束

1. 优先以完整旧远端作源，校验后原字节迁移 envelope、operations、blob、retention 与 commit，commit最后发布；不得改ID/序号或覆盖冲突对象。
2. 若希望以后不依赖旧远端，可信生产端需在暴露READY前持久化原包归档，并定义磁盘预算、保留与GC规则；不能无界复制用户相册。
3. 补传必须按目标隔离，涵盖所有贡献生产者；已有回执/进度不等于新远端完成。
4. 单独验收中断重试、不可变对象冲突、缺包/缺blob拒绝、跨设备实际解密、删除历史与大文件性能。

### 实际UI复核补充

`history-reject-02` 再次通过，并在测试期间保存实际界面截图。人工检查看到“上次失败”“最近同步 失败·刚刚”“上次同步未完成”，以及完整中文处理提示；不再显示“已保护”。测试退出后普通截图是桌面，不作为UI证据。有效截图为 `ui_test_results/tutorial-20260919/retakes/history-reject-02/history-incomplete-rejected.png`。

静态分析无问题。连续性列表门禁测试和真实checkpoint/runner测试再次执行，补充覆盖原远端commit齐全后正常完成，不将测试用占位字节称为恢复成功。
