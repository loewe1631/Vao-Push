# 更新记录 / Changelog

## 1.0.0

- Linux amd64、arm64 预构建服务端安装包，安装时自动配置官方客户端的 Production APNs 身份。
- 中文 / English 安装向导；默认 API 8188、Web 18188、`admin` 与随机 24 位初始密码。
- 支持 IP HTTP、域名自动 HTTPS、已有 HTTPS 反代、自带证书。
- Web 概览、设备管理、手动多选发消息、默认接收列表。
- JSON/API 数据源、字段映射、卡片设计、AI 辅助 JSON 草稿导入、发布与订阅。
- iOS / iPadOS 客户端支持多服务器连接、消息历史与详情跳转、卡片订阅与本机微调、中文/English 与明暗外观。
- 首次安装自动导入推送身份；续装及升级保留配置、用户数据和已有身份。
- 管理工具包含日志、启停、备份、隔离恢复检查及带健康检查的升级。

客户端与服务端均使用 Production APNs 协议；兼容的客户端更新通常无需重新部署服务端。

Prebuilt Linux amd64/arm64 server packages configure the official client's production push identity automatically. Installation supports Chinese and English, configurable API and Web ports, HTTP and HTTPS modes, persistent data, backups, restore checks, and health-checked upgrades. The iOS / iPadOS client supports multiple self-hosted servers, message history and detail navigation, Web card subscriptions, local adjustments, Chinese/English, and light/dark appearance.
