# 实现概览与验证边界

本仓库包含 iOS / iPadOS 客户端、通知扩展、Widget、Go/PostgreSQL 服务端、Vue Web 控制台和 Linux 安装工具。

## 已实现模块

- 自动设备注册和设备专属发送 Key。
- 消息历史、最新状态、游标同步、幂等请求和持久发送队列。
- Web 登录、CSRF、防止跨设备越权、手动多选发送和默认接收列表。
- JSON/API 数据源、字段映射、数据采集周期、卡片草稿、可视化布局、发布和订阅。
- App 内消息详情、通知点击直达详情、服务器隔离、Keychain 凭证存储、共享 SQLite、中文/English 和明暗主题。
- 安装向导、HTTP/HTTPS 访问模式、独立 API/Web 端口、备份恢复和带健康检查的升级。
- 安装包可以在首次启动时将包内 APNs 身份加密导入；升级到含身份的包时，未配置身份的旧安装也会导入，已有人工配置不会覆盖。

## 验证命令

```sh
cd server && go test -race ./... && go vet ./...
cd web && npm ci && npm test && npm run build
cd ios/VaoPushCore && swift test
```

这些命令验证对应源码层的行为。真实 APNs 投递、低电量/强退和系统 Widget 刷新调度仍取决于具体运行环境与 iOS 系统预算。

## 公开发布边界

1.0.0 服务端正式安装包在私有发布步骤中加入产品专用 Production APNs 身份，源码不包含私钥。首次安装、续装、备份恢复和无身份旧安装升级均提供自动化与隔离验证工具。
