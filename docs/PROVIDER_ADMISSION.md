# Provider 准入状态

本文件记录 Provider 是否能在移动端以公开客户端安全接入；它不是账号或
Token 配置清单。凭证只保存在平台安全存储中。

| Provider | 状态 | 决策 |
| --- | --- | --- |
| WebDAV | 已实现 | 使用用户提供的 WebDAV 凭证。 |
| Google Drive | 已实现 | 系统浏览器 + PKCE 公开客户端；使用 `drive.file` 最小 scope。 |
| OneDrive | 已实现 | 系统浏览器 + PKCE 公开客户端；使用用户文件权限和 `offline_access`。 |
| 百度网盘 | 暂缓 | 官方 code 换 Token 及 refresh 都要求 `client_secret`；必须先提供独立、最小权限的 Token Broker。 |
| 阿里云盘 | 暂缓 | 官方 PDS code 换 Token 及 refresh 都要求 `client_secret`，且应用须在开发者域中创建；必须先提供独立、最小权限的 Token Broker。 |

## 启用暂缓 Provider 的前提

1. 部署并审核一个独立的 Token Broker，secret 仅存在于 Broker；移动端只
   使用 PKCE、一次性授权码和 Broker 返回的短期/可刷新的凭证引用。
2. Broker 必须限制到单一 Provider 与最小 scope，审计请求，不记录完整
   Token，并具备撤销和轮换流程。
3. 为该 Provider 实现 `RemoteObjectStore`、公共 Provider 契约测试和错误映射
   后，才可以在连接 UI 中开放。

依据：百度 OAuth 文档将 `client_secret` 列为授权码与 refresh 换 Token 的必填
参数；阿里云盘 PDS 文档同样要求应用 ID、Secret，并要求在 Token 请求中提交
`client_secret`。参见[百度 OAuth 接入指南](https://openauth.baidu.com/doc/doc.html)
和[阿里云盘 PDS OAuth 文档](https://help.aliyun.com/zh/pds/drive-and-photo-service-dev/user-guide/oauth-2-0-access-process-for-web-server-applications)。
