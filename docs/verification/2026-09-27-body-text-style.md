# iOS 正文异常字号与黄色双下划线

用户截图：远端目录 `/USB_HDD_8T/6` 变成三行大字；传输记录详情弹层的标题、字段、值和技术详情全部带黄色双下划线。

根因：迁移到 MaterialApp + CupertinoPageScaffold 后，页面正文未设置 DefaultTextStyle；CupertinoPageScaffold 和自定义 Cupertino popup 不会替正文设置默认样式，继承了 MaterialApp 的诊断文字（48pt、粗体、黄色双下划线）。只指定颜色或字号的 TextStyle 仍会继承其他异常属性。

修复：AdaptivePageScaffold 与 AdaptiveTabScaffold 的 Apple 正文、showAdaptiveSheet 的 Apple popup 路由分别设置 CupertinoTheme.textTheme.textStyle。popup 独立于页面，必须在 popup 内设置。使用 DefaultTextStyle 而非 merge，避免继续继承诊断装饰；保留系统文字缩放及主题。AdaptiveSliverScaffold 已有透明 Material 提供正文样式，无需改动。未修改同步协议和远端数据。

验证：

- 新增 adaptive_body_text_test：iOS/Android × 浅色/深色，检查实际 RenderParagraph 字号、字重和装饰；涵盖页面、tab 正文和记录弹层标题/字段/技术详情。修复前 iOS 确实读到 48pt。
- connection_loading_test 新增真实 Connection 页面路径回归：440pt 宽度下路径为 14–18pt，无装饰，高度 <30pt。保留加载时 Element/位置不变、禁用旧列表、失败返回等检查。
- 原 50 项相关测试全通过，新增目录回归后 connection_loading_test 12 项通过（其中 10 项与前述重叠；合计 52 项）；独立 run_conclusion_visual_qa_test 另 1 项通过。修改范围静态分析无问题。
- 真实字体 widget 渲染位于 `/Users/parcool/.codex/work/velock-body-text-20260927/`，已检查路径与记录弹层无黄色下划线。数据为内存 fixture，不是设备业务数据。
- `flutter build ios --simulator --debug --no-pub` 成功，通过 XcodeBuildMCP install / launch-app 安装启动到既有 iPhone 17 Pro Max（26CC5821-DEF4-47D3-978D-A11D7293AD61）；设备截图确认新版首页正常启动。
- 设备两处页面未完成自动点击复核：XcodeBuildMCP 的 axe 缺失 SimulatorKit.framework；Computer Use 连接超时后按 bundle ID 重试仍不可用。未擦除或新建设备。截图中的远端目录不存在属于另一个同步错误，本次样式修复不宣称已解决。
