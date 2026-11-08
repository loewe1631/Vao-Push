# 更新记录 / Changelog

## 1.1.0

### 卡片工作台维护修正

- Web 预览保留空文字与文本字段原文，修正 signed 数字颜色和零值判断，补齐深色预览及图表时间间隔。
- AI 设计说明支持 schema 1 / 2、按尺寸布局及根字段 / 列表项作用域，保护已有节点身份与旧版默认布局。
- 设计器提供现有节点组成的圆角分组、静态文字胶囊及按字段类型显示的数值设置。
- 发布前显示布局规模、字段与样式提示以及可能影响本机微调的节点变化；可选检查令牌避免发布已过期的检查结果。
- 延续 App 1.0.0 / 1.1.0 的现有协议，无需重打包客户端。

These source maintenance fixes improve native-preview consistency, schema 2 AI instructions, existing-node compositions, and administrator publication checks. Existing app 1.0.0 and 1.1.0 clients remain supported. Prebuilt downloads remain identified by the assets published on the Release page.

### 初始发行

- 新增命名推送列表，支持独立发送地址、设备管理、改名和删除；保留原默认地址。
- 新增同一卡片的尺寸布局覆盖、固定预览和溢出提示；未声明支持的旧客户端继续读取v1默认布局。
- API/Web支持逐条指定可选HTTPS图标，旧客户端继续使用原文字消息。
- 新增签名Web更新与独立本机执行器；首次安装及一次保留数据的`--upgrade`自动启用，之后通过页面检查并确认升级。
- 保留App 1.0.0的已有接入、消息同步和卡片订阅能力。服务端升级不要求手机同步升级。
- 本次为服务端/Web发行；需要新客户端的原生呈现功能随支持客户端提供。

Named push lists, per-size card layouts, optional notification icon metadata, signed Web updates and automatic updater setup during fresh installation/in-place upgrades. Existing app 1.0.0 features remain supported. This is a server/Web release; new native presentation features require a supporting app version.

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
