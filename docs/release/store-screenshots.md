# App Store 截图与文案（跨会话入口）

要改商店截图或文案时**先读这一篇**，不要重新摸索流程。

## 现状（2026-10-03）

- Sync 是 **iPhone-only**（`TARGETED_DEVICE_FAMILY = 1`，自 1.0.1 起）。商店只有
  iPhone 6.7 寸一种尺寸，**不要再生成 iPad 截图**；`all_shots.sh ipad` 的代码还在
  但不是交付物。
- 每种语言 8 张，18 种应用语言铺到 24 个 App Store 地区（`recompose.sh` 里的
  `locales_for`）。交付目录 `tool/store/screenshots/<地区>/iphone-NN-*.png`。
- 线上 1.0.0 用的是旧样式（平板外壳、单色渐变背景）。仓库里现在是新样式
  **`deep`**（深蓝渐变 + 光晕，iPhone 16 Pro 外壳：真实圆角、灵动岛、钛金属边框、
  侧键）。1.0.0 在审核中无法换图——**截图是 Waiting for Review 期间唯一锁定的
  元数据**，要换必须撤出审核队列重新排队。新样式随下一个版本上。

## 三条路，按代价从低到高

### 1. 只改画框（样式、外壳、标题排版）— 约 2 分钟，不用模拟器

```bash
tool/store/recompose.sh
```

从 **`tool/store/raw/<lang>/`**（已提交进仓库的原始截屏，18 种语言 × 8 张，43 MB）
重新套框，写入 `ui_test_results/store/framed/` 并复制到交付目录。可以只做某几种
语言：`tool/store/recompose.sh deep zh en ja`。

原始截屏之所以进版本库，就是为了**换一台机器或干净克隆也能直接重出图**，不必再
跑模拟器。它们只含演示身份（`homenas.local:5005`、`cloud.local:8080`、Nextcloud），
没有真实 NAS 名称或路径——本仓库公开，重新采集后替换时要再确认这一点。

样式定义在 `tool/store/compose.py` 的 `STYLES`（`deep` / `light`），设备尺寸写在
`GEOMETRY`（按真机比例：iPhone 16 Pro Max 圆角 62pt、灵动岛 126×37pt）。

### 2. 只改文案（标题/副标题）— 同样不用模拟器

改 `tool/store/shot_strings.json` 的 `captions`，再跑 `recompose.sh`。

### 3. App 界面本身变了 — 要模拟器，每种语言约 4 分 20 秒

```bash
tool/store/all_shots.sh iphone <udid>[,<udid>…] [lang …]
```

需要一台跑过 `tool/ios_ui_test/sim/e2e.sh` 的模拟器（格间备份已配对）。成功后会
自动刷新 `tool/store/raw/<lang>/`，记得一起提交。多台逗号分隔可并行，但 `simctl clone` 出来的克隆机**仍指向原机的 App 数据目录**，
克隆后必须在克隆机上 `uninstall` 再 `install` Sync 和 `CrossAppUITestHost.app`。
用完删除克隆机。演示 WebDAV 端口 5005/8080 被旧进程占用会直接报错。

## 看线上实际是什么

```bash
python3 tool/store/export_from_asc.py <输出目录>
```

把两个 App 商店页**当前实际在用**的文案（24 地区 × 每个字段一个文件，带字数）和
截图全部拉下来。只读，不写 App Store Connect。需要仓库外的私钥
`~/.velock-release/asc.py` + `asc_api_key.json`（`VELOCK_RELEASE_DIR` 可改路径）。

## 上传

截图：`~/.velock-release/sync-shots/fastlane/Deliverfile`（`skip_metadata`，不提审）。
文案：`~/.velock-release/sync_push_meta.py`（ASC API 直推 `tool/store/metadata/` 下
24 个地区）。文案源文件在仓库里，截图源文件也在仓库里，私钥和审核账号不在。

## 不要重复踩的坑

- 商店截图里**不要**按中英文文字定位控件：`testStoreShots` 按位置点底部 tab
  （阿拉伯语整个界面是镜像的）、返回用 `app-back`、新建连接用 `connection-new`，
  等待的状态文字由 `shot_env.py` 查翻译表后传进去。
- 字体按语言选（`compose.py` 的 `font()`）：阿拉伯语用 Arial 而不是 SF Arabic，
  后者没有拉丁字母，产品名会变成豆腐块。
- 格间（Velock）的截图是另一套东西——`velock_codex` 仓库的
  `appstore_screenshots/`，玻璃卡片 + 光台的设计稿，没有设备外壳，和这里无关。
