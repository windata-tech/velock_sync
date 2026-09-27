# 返回箭头与内容左边缘对齐（2026-09-26）

## 原因与修复

上一轮只改了iconSize、验证了44触控区，漏掉了实际可见图形与内容的横向对齐。Cupertino导航额外16px起始padding叠加了44px按钮内居中的字形留白，箭头比白色卡片左边界右移约16px。

本轮以白色内容卡片的外侧左边界（页面16逻辑像素）为对齐基准，不是卡片内部文字边界：

- WDAppBar的AppBackButton去除Cupertino额外leading inset；其他自定义leading保持原样。
- Material仅在AppBackButton时固定leading槽44，避免框架56槽位另加6px偏移。
- 大标题与紧凑Sliver页头采用相同规则，根页面无返回时不改变布局。
- 箭头32、触控区至少44、辅助标签与PopScope行为保持。
- “原来的备份找不到了？”按钮同步从20改为页面16边距，与卡片同宽同左边界。

## 回归与视觉证据

- iOS/Android、普通/大标题/紧凑页头新增图标位置断言。
- 真实MaterialIcons字体渲染，对截图RGBA像素扫描，识别蓝色箭头最左侧着色像素，与卡片DecoratedBox左边界比较，容差1.5逻辑像素；不再拿Icon或触控框尺寸冒充实际视觉对齐。
- 次操作按钮和白卡边界做坐标相等断言；维持原有大字/中英/返回及备份流程测试。
- `flutter test test/widgets test/features/cloud_backup test/features/connection`：221项通过；五文件analyze无问题。
- 已在原iPhone 17 Pro Max模拟器上Debug构建安装启动，未新建/擦除设备、未触发NAS备份或选择目录。
- 测试与构建日志位于项目外 `../velock_sync-artifacts/work/back-alignment/`。`history-help.png`为真实字体widget渲染，区分于模拟器截图。

## 模拟器实屏复核

构建后经只读导航“查看原因和下一步”打开“找回备份位置”，已查看实际Simulator截图 `help-back-alignment-cua.png`：箭头可见笔画与白卡外侧及次按钮左边界对齐，页头标题居中。未点选/确认目录或触发备份。实屏验证与widget像素回归一致；不能把卡片内按钮或内文左边缘误用为外侧页面边距。
