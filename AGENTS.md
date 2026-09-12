# AGENTS.md

本文件是本仓库的项目级记忆（Codex / 协作者共用）。

## WebDAV

### 1. 用户 NAS（远程，联调主用）

- 地址、账号、密码记录在 `tool/local_webdav/nas_webdav.local.env`（已 gitignore，**禁止提交、禁止复制到受版本控制的文件**）。
- 需要凭据时先读该文件，例如：`set -a; source tool/local_webdav/nas_webdav.local.env; set +a`，再用 `curl -u "$WEBDAV_USER:$WEBDAV_PASSWORD" ...`。
- NAS 文件系统路径 `/vol4/1000/USB_HDD_8T/velock-sync` 在 WebDAV 上对应的真实目录是 `parcool 共享给我/velock-sync`（共享名带空格和中文，URL 需编码）。
- 若认证返回 401 或路径 404，先核对本文件记录并向用户确认，不要猜测或改写凭据。

### 2. 本机测试服务（WsgiDAV）

- `tool/local_webdav/start_local_webdav.sh [start|stop|restart|status]`，默认端口 8888、账号 `velock` / `velock123`，数据根目录 `ui_test_results/persistent-webdav-root`。
- 这是模拟器/本机自测用的假服务，与上面的 NAS 无关，勿混用凭据。
