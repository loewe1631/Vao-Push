# Vao Push：接口与卡片数据协议 v0.1

两路接口说明与实现边界。实际身份接口和限额以当前源码与公开安装文档为准。
配套：[产品与技术设计](design.md)、[实现概览](implementation.md)。

## 0. 当前首选：简单接入

当前简化接入方式：普通客户端只填写服务器地址自动注册，不要求登录、配对、建分组、预建数据流或配置 scopes。首选发送接口：

- `POST /v1/push/{key}`，最简正文 `{"body":"任务完成"}`。
- `PUT /v1/state/{key}/{data_id}`，最简正文 `{"fields":{"progress":{"type":"percent","value":"68"}}}`；首次合法写入自动创建数据 ID。

注册、内部身份、默认值和兼容见[简单接入](simple-onboarding.md)。默认消息 Key 按 Web 保存的接收设备列表自动分发，设备专属 Key 仍只对应单设备；新设备各有独立状态作用域。手动发送可临时多选，且不更改默认列表。下文分组与范围凭证属于兼容接口，不是普通用户的接入前置条件。

## 1. 接口原则

服务端不限定请求来源。Bot、脚本、业务系统、自动化工具、人工 HTTP 请求都使用相同协议；不要求申报工具类型。Web 手动发送使用登录会话调用同一内部接收与分发服务。

两路能力独立：

| 路径 | 用途 | 保存方式 |
| --- | --- | --- |
| `POST /v1/messages` | 接收一条消息并请求发送系统通知 | 每条事件独立保存 |
| `PUT /v1/widgets/{data_id}/state` | 更新一个数据流的完整最新状态 | 同一 ID 替换最新内容 |
| `GET /v1/widgets/{data_id}/state` | 手机读取已整理好的最新快照 | 只读，不访问上游业务 API |

`data_id` 表示内容源，不代表桌面某张卡片。`card_id` 表示手机保存的展示配置。一个数据 ID 可以绑定多张卡片，接收接口不能修改卡片别名、布局和交互状态。

所有接口使用 HTTPS 和 UTF-8 JSON。示例数字均为虚构，示例域名、ID 和凭证不指向实际账号。

新增[多服务器补充](multiple-servers.md)：客户端同时绑定多台服务，服务发现为 `GET /v1/info`；本地缓存按连接与账号隔离，推送携带受控 `server_id` 与 `binding_id`。这两个标识不是外部发送方可自行指定的路由权限。

## 2. 身份与权限

| 身份 | 当前用途 |
| --- | --- |
| 自动生成的发送 Key | 仅向对应设备发消息、写状态；可放入复制的专属发送 URL，或使用 Bearer 请求头 |
| Web 默认消息 Key | 按当前保存列表发消息；不能指定其他目标、写状态、读历史或改列表 |
| App 私有设备凭据 | 注册本设备 APNs token、同步、关注关系、暂停与移除 |
| Widget 共享读取凭据 | 仅访问本设备关注的快照及注册专用 Widget token |
| Web 管理会话 | 管理该服务器的接入设备并手动发送；验证来源与 CSRF |
| APNs 发送身份 | 产品方的服务端发送模块持有 |

发送 URL 是秘密，需妥善保管，不嵌入公开网页。服务端以摘要验证发送 Key，并加密保存其恢复副本；旧的限定范围 sender_token 仍只保存摘要。新自动注册设备的 data_id 各自隔离，旧配对设备保持原账号作用域；本地仍按连接与内部身份隔离。任何 ID 都不能代替归属校验。

## 3. 消息通知端点

### 3.1 请求

```http
POST /v1/messages
Authorization: Bearer <sender_token>
Content-Type: application/json
Idempotency-Key: example-job-finished-001
```

```json
{
  "schema_version": 1,
  "target": {"group_id": "group_personal"},
  "title": "任务完成",
  "body": "示例任务已经完成，可以查看结果。",
  "notification": {"level": "active", "sound": "default"},
  "url": "https://example.com/jobs/demo",
  "ttl_seconds": 3600
}
```

- Web 的 `target` 四选一：`device_id`、`device_ids`、`group_id` 或 `all_devices: true`。`device_ids` 接受1至250个标识，去重并验证所有设备归属及接收状态；失效或越权则整次拒绝，不部分发送。列表/全部仅供 Web 管理会话。设备专属 Key 或默认消息 Key 省略目标，由服务端确定，不能扩权。分组、全部和默认列表均在入库时固化目标；重试不随列表变化改变接收人，没有有效目标返回422。每台目标拥有独立 outbox 和自己的推送身份作用域，手机只同步明确发给自己的消息。
- `title` 可以省略，`body` 为非空文本；首版不解析远程 HTML 或可执行内容。
- `notification.level` 首版为 `active` 或 `passive`，默认 `active`。`sound` 为 `default` 或 `none`。系统授权、专注模式和用户设置仍决定实际表现。
- `url` 可选，首版仅接受 HTTPS 链接；由用户主动点击打开，不进行服务端抓取。
- `ttl_seconds` 为等待发送有效期，建议 1–86400，默认 3600；超时终止尚未完成的发送。它不表示通知会在显示后自动从系统列表消失。
- 不允许请求直接注入任意 `aps`、APNs topic、优先级、critical alert 权限或签名信息。新增能力应有明确字段和验证规则。

### 3.2 响应与幂等

```json
{
  "request_id": "req_demo_001",
  "data": {
    "message_id": "msg_demo_001",
    "status": "queued",
    "target_count": 1,
    "received_at": "2026-10-24T10:00:00Z"
  }
}
```

首次接受返回 202，且必须已经同事务提交消息和持久发送任务。没有有效目标设备返回 422，不伪称已发送。`queued` 仅表示已排队。

`Idempotency-Key` 建议每次逻辑发送提供，Web 自动生成。同一用户、同一操作、同一键在保留窗口内只产生一条消息：相同规范化请求返回同一消息 ID；内容不同返回 409 `idempotency_conflict`。建议窗口 24 小时；超过窗口后不承诺去重。不提供键时每个请求都是新的事件。

一次消息可有多个设备发送结果，不能用一个“成功”掩盖部分设备失败。Worker 重试可能造成 APNs 重复投递；使用稳定消息标识尽量去重，但不承诺跨网络、跨设备端到端恰好显示一次。

## 4. 小组件状态写入端点

### 4.1 基本请求

数据流由 Web 或管理接口提前创建。其 `data_id`、显示名称、有效期默认值、目标权限和排序模式都是管理配置。用户不需要先收到推送，才能在 App 中选择一个已存在的数据流。

```http
PUT /v1/widgets/demo_quote/state
Authorization: Bearer <sender_token>
Content-Type: application/json
Idempotency-Key: demo-quote-update-001
```

```json
{
  "schema_version": 1,
  "source_updated_at": "2026-10-24T10:00:00Z",
  "valid_for_seconds": 180,
  "title": "示例数据",
  "fields": {
    "name": {"type": "text", "label": "名称", "value": "DEMO"},
    "price": {"type": "decimal", "label": "价格", "value": "123.45", "unit": "USD"},
    "change_24h": {"type": "percent", "label": "24h 涨跌幅", "value": "1.25"},
    "high_24h": {"type": "decimal", "label": "24h 最高", "value": "125.00", "unit": "USD"},
    "low_24h": {"type": "decimal", "label": "24h 最低", "value": "120.00", "unit": "USD"},
    "volume_24h": {"type": "decimal", "label": "24h 成交量", "value": "10000", "unit": "DEMO"},
    "funding_rate": {"type": "percent", "label": "资金费率", "value": null}
  },
  "series": {
    "price_1m": {
      "type": "ohlc",
      "label": "1 分钟 K 线",
      "interval_seconds": 60,
      "unit": "USD",
      "points": [
        {"t": "2026-10-24T09:58:00Z", "o": "122.80", "h": "123.20", "l": "122.70", "c": "123.00", "v": "25"},
        {"t": "2026-10-24T09:59:00Z", "o": "123.00", "h": "123.60", "l": "122.90", "c": "123.45", "v": "30"}
      ]
    }
  }
}
```

示例中的金融名称不代表服务端内置金融业务；`temperature`、`cpu_load`、`task_status` 等均可作为字段。最简状态可以只包含版本、来源时间和一个文本字段。

### 4.2 全量替换与空值

PUT 是整份状态替换，不是局部合并。省略旧字段意味着最新快照不再含该字段；手机仍保留其绑定设置，显示不可用。若要恢复它，发送方在下一份完整状态中带回。

| 值 | 含义 | 展示建议 |
| --- | --- | --- |
| 字段缺失 | 本次完整快照不包含此字段 | 不可用，保留绑定 |
| `value: null` | 字段存在，但当前没有可用值 | 不可用 |
| `value: "0"` | 有效的数值零 | 按格式显示 0 |
| 文本 `value: ""` | 有效空文本 | 按空文本规则展示，不改成数值零 |
| `items: []` 或空序列 | 明确没有项目或点 | 显示空状态 |

请求失败时不能以空状态替换上一份有效数据。客户端不使用 `value || 0` 一类规则混淆空值与零。

### 4.3 排序、重复与版本

每个流选择一种排序模式，与发送工具无关：

| 模式 | 适用 | 规则 |
| --- | --- | --- |
| `server_order`（默认） | 简单脚本、人工更新、一般接入 | 按服务端事务提交顺序覆盖；不要求发送方维护序号 |
| `source_sequence`（可选） | 需要抵御上游乱序的持续更新 | 每次提交增加字符串字段 `sequence`，必须为该流持久递增正整数 |

`source_sequence` 示例额外字段为 `"sequence": "1001"`。建议范围 1–9223372036854775807，使用字符串防止 JavaScript 整数精度丢失。同一流首版推荐一个活动逻辑写入者；进程重启需恢复序号。需重置时显式更换流或管理端重置排序代次，不可静默回到 1。

- 大于已接受序号：接受，服务端递增 `revision`。
- 等于最近序号且规范化内容相同：返回相同版本，不新建更新任务。
- 等于最近序号但内容不同：409 `sequence_conflict`。
- 小于已接受序号：409 `stale_sequence`，不覆盖内容。
- 更早请求若有仍有效的幂等键，可直接返回其原始处理结果；该结果的旧版本不表示它现在仍是最新状态。

`server_order` 可配 `If-Match` 执行条件写入。Web 编辑既有状态必须携带读取时的 ETag；版本已变化返回 412，提示重新读取，禁止静默覆盖。没有条件时，服务端无法凭客户端时间戳辨识迟来的旧业务内容，最后提交的新请求可能覆盖较新的业务数据。对乱序敏感的接入应选择序号模式。

两种模式均支持 `Idempotency-Key`。在有效窗口内相同键不重复执行写入；不同内容复用该键返回 409。无键但与当前完整状态完全相同的 PUT 返回原版本，不新增任务。规范化仅忽略 JSON 对象键顺序和空白，数组顺序、字符串内容和十进制字符串表示保持有意义。

首次接受一个新状态返回 202：

```json
{
  "request_id": "req_demo_002",
  "data": {
    "data_id": "demo_quote",
    "revision": "8",
    "received_at": "2026-10-24T10:00:01Z",
    "status": "stored",
    "dispatch_status": "queued"
  }
}
```

重复且未改状态返回 200。状态保存和更新任务同事务提交；没有已订阅设备时仍可保存，`dispatch_status` 为 `no_subscribers`，不能声称已推送。新卡片稍后可以读取此状态。

`revision` 是服务端在当前流身份内单调增加的版本字符串。手机只接受较新版本；数据流删除后重建使用新的内部流身份，避免同名流的版本重置被手机误判。并发校验、更新和任务创建都在数据库事务内完成。

`source_updated_at` 只表达业务时间，不参与默认排序。它使用 UTC RFC 3339；`received_at` 由服务器生成，两者不互相冒充。

## 5. 通用字段、项目与序列

### 5.1 字段

`fields` 是 key 到字段对象的映射。key 稳定且在所属作用域唯一，建议 `[A-Za-z][A-Za-z0-9_]{0,63}`。`label` 是可选默认名称，不是客户端绑定身份；省略时显示 key。`unit` 是展示单位，不能隐式触发币种换算。

| `type` | 非空 value 类型 | 说明 |
| --- | --- | --- |
| `text` | 字符串 | 按文本显示 |
| `decimal` | 十进制字符串 | 不使用浮点 JSON 数字传递金额等值 |
| `integer` | 有符号整数字符串 | 避免大整数丢精度 |
| `percent` | 十进制字符串 | `"1.25"` 就是 1.25%，不是 125%；不再隐式乘 100 |
| `boolean` | JSON 布尔值 | 手机可选择“是/否”等显示格式 |
| `datetime` | UTC RFC 3339 字符串 | 手机按时区和用户格式显示 |

以上类型均允许 `null`。十进制建议最多 38 位有效数字、18 位小数，不接受 NaN、Infinity 或指数表达式；超出支持精度返回 422，不能静默舍入。字段类型变化时保留绑定但验证格式兼容性，无法格式化则显示不可用并在编辑器说明。

### 5.2 多项目

需要一张卡片展示多个币种、服务器或任务时，可附加 `items`。每个项目有稳定的 `item_id` 和自己的 `fields`，不按数组下标绑定：

```json
{
  "items": [
    {"item_id": "server_a", "fields": {"name": {"type": "text", "value": "示例服务器 A"}, "cpu": {"type": "percent", "value": "12.5"}}},
    {"item_id": "server_b", "fields": {"name": {"type": "text", "value": "示例服务器 B"}, "cpu": {"type": "percent", "value": "21.0"}}}
  ]
}
```

上例是状态中的可选片段，完整请求仍需 `schema_version`、`source_updated_at`。顶层 `fields` 和 `items` 至少提供一个容器，允许 `fields: {}` 或 `items: []` 明确表示当前没有内容。项目删除或暂时消失时保留卡片选择，不能让其悄悄改绑到数组下一项。项目也可以有与顶层相同结构的 `series`。

### 5.3 折线与 OHLC

- `line` 点结构为 `{"t":"2026-10-24T09:59:00Z","value":"123.45"}`。
- `ohlc` 点结构见完整示例；`o/h/l/c` 必填，`v` 可选且非负。验证 `h >= max(o,c)`、`l <= min(o,c)`、`h >= l`，不人为要求价格为正。
- `t` 是点或蜡烛的开始时间，UTC，必须严格递增且无重复。`interval_seconds` 声明固定周期；不连续点可以存在，不填造缺失蜡烛。
- 可选 `is_closed` 标明蜡烛是否收盘；省略表示未知，不默认已收盘。
- 不接受某根蜡烛中部分必需数值为空；无数据使用空序列。客户端显示最近有效序列，不能从当前值自行伪造历史。
- 首版图表按等间隔/时间轴原生绘制，不执行服务端绘图代码；过多数据明确拒绝，不静默裁剪到不知所云。

## 6. 快照读取与设备关注关系

```http
GET /v1/widgets/demo_quote/state
Authorization: Bearer <device_read_token>
If-None-Match: "state-demo-stream-8"
```

变化后返回 200 与新的 ETag：

```json
{
  "request_id": "req_demo_003",
  "data": {
    "stream_id": "stream_demo_001",
    "data_id": "demo_quote",
    "revision": "9",
    "received_at": "2026-10-24T10:01:01Z",
    "state": {
      "schema_version": 1,
      "source_updated_at": "2026-10-24T10:01:00Z",
      "valid_for_seconds": 180,
      "fields": {"price": {"type": "decimal", "value": "123.50", "unit": "USD"}}
    }
  }
}
```

未变化返回 304、无响应体；客户端保留内容和原业务时间。响应使用 `Cache-Control: private, no-cache`，允许条件校验但不允许公共 CDN 混用私人快照。请求失败保留原缓存，不用错误页或空对象覆盖。

首次 App 登录先同步数据流清单和所选快照。保存卡片后，App 同步本设备关注的数据 ID，服务端据此分发更新。桌面实际安装情况以系统可查询信息为辅助，不能假定保存一张卡片就已经添加到桌面。

普通通知 token、WidgetKit 专用 token、内部 `device_id` 三者分别管理：

1. App 登录后注册内部设备，普通通知 token 到达或改变时更新服务器。
2. Widget Extension 根据官方 token 回调注册或更新专用 token，关联已认证设备；不可要求外部发送方直接提交 token。
3. 记录环境、Bundle/扩展身份、有效状态和更新时间，开发与生产隔离。
4. APNs 明确 token 失效时停用，之后收到新 token 再恢复；账号解绑同时撤销设备读取权限和发送路由。
5. 专用推送按苹果实际注册粒度合并；不假设一个卡片或一个数据 ID 对应一个 token。

路线 A 以完整内容承载更新，走通知扩展保存；路线 B 发专用失效信号，再读取快照。具体 APNs topic、push type、payload 和 token 格式按官方 SDK 规范实现，不用猜测的请求格式当正式协议。两路选择不改变公开状态写入接口。

## 7. 卡片配置协议

卡片配置由手机创建，不由状态接口下发。建议结构：

```json
{
  "config_version": 1,
  "card_id": "card_demo_001",
  "data_id": "demo_quote",
  "stream_id": "stream_demo_001",
  "name": "我的示例行情",
  "template": "metric_list",
  "supported_families": ["systemSmall", "systemMedium"],
  "selection": {"scope": "root"},
  "fields": [
    {"key": "price", "alias": "当前报价", "visible": true, "format": {"decimals": 2, "show_unit": true}},
    {"key": "change_24h", "alias": "当日变化", "visible": true, "format": {"decimals": 2, "show_sign": true}},
    {"key": "volume_24h", "alias": "成交数量", "visible": false, "format": {"compact": true}}
  ],
  "style": {"theme": "system", "alignment": "leading", "positive_color": "green", "negative_color": "red"},
  "chart": {"series_key": "price_1m", "default_mode": "summary", "allow_toggle": true}
}
```

- `fields` 数组顺序即用户顺序，`alias` 优先于上游 label。删除别名后才回到默认名称。
- `selection.scope` 可为 `root`、`item`、`items`；后两者附 `item_ids`，字段 key 在各项目内解析。图表首版绑定 root 或一个具体 item，避免多项目同名序列歧义。
- `supported_families` 是配置可适用尺寸；编辑器逐个尺寸校验容量。小尺寸容纳不下时给出预览和明确限制，不隐藏用户的必选主值。
- `format` 只影响显示，不修改原数据。百分比按协议直接格式化；`show_unit`、小数位、紧凑计数等须受字段类型支持。
- 样式使用预定义枚举和有界参数，首版不接受 HTML/CSS/JavaScript/Swift、任意网络字体或脚本执行。
- 当前显示“概览/图表”的交互状态单独保存，首版建议按 card_id 与尺寸区分，不能仅按 data_id 存一份全局状态。相同卡片、相同尺寸的多个桌面实例可共享切换状态；需要独立状态时复制卡片。不假定 WidgetKit 提供可直接使用的永久实例 ID。
- 删除卡片后，已经摆在桌面的实例显示“卡片已删除，请重新选择”；不能自动改成另一张私人卡片。

App Group 共享存储分表管理：数据快照、卡片配置、交互状态。写入以事务或原子替换完成，不在半份数据状态下请求刷新；短事务、并发读写、迁移版本和扩展终止恢复均需验收。

若启用云备份，备份版本和冲突规则属于独立配置同步协议，不借用状态 `revision`。本地保存、账号备份、跨设备实时同步属于不同范围。

## 8. Web 手动发送

首版必须提供正常用户可访问的“发送消息”页：

1. 选择一台接入设备（首版不要求创建分组）。
2. 填写标题、正文及支持的通知选项，可选链接。
3. 点击发送，Web 自动生成幂等键，提交期间禁用重复点击。
4. 显示校验错误或 message_id，之后展示每设备处理结果。
5. 需要再发一条时产生新幂等键，不能复用上一条操作导致被去重。

Web 不需要收集“来自 Bot 还是脚本”，也不要求用户粘贴发送凭证。登录身份提供权限；审计仅标注入口为 Web 或 API，便于排障，不影响内容能力。

状态页已支持手动更新：字段表单用于简单数据，JSON 编辑用于复杂项目或序列。提交与 API 经过相同校验、存储、限流和分发流程；不是浏览器直接访问 APNs。默认排序模式下携带 ETag 防并发覆盖；序号模式需明确当前序号与写入者约束，不能为方便编辑偷偷绕过序号校验。

## 9. 辅助 API 范围

下表保留早期扩展/兼容接口范围。当前自动接入仅使用简单接入文档所列流程，账号和复杂授权不是首版前置条件：

| 能力 | 建议端点 |
| --- | --- |
| 用户、会话和删除账号 | `/v1/account`、`/v1/sessions` |
| 设备与分组管理 | `/v1/devices`、`/v1/groups` |
| 发送凭证创建/撤销 | `/v1/sender-tokens` |
| 数据流清单与创建/删除 | `/v1/data-streams` |
| 设备关注列表 | `PUT /v1/devices/{device_id}/subscriptions` |
| 普通/小组件推送注册 | `/v1/devices/{device_id}/push-endpoints`，各类 token 分开记录 |
| 消息查询与游标同步 | `GET /v1/messages`、`GET /v1/messages/{message_id}` |
| 分发任务查询 | `GET /v1/dispatches`，只返回本人记录 |
| Web 手动接入 | `/v1/web/messages`、`/v1/web/data-streams/{data_id}/state`；会话鉴权后调用相同应用服务 |

列表接口采用有界分页与稳定游标；消息删除不删除数据状态。设备与订阅变更必须验证归属，不能将用户请求中的 user_id 当成可信授权来源。外部接口和 Web 接口限流都计入同一用户额度，避免绕过。

## 10. 错误与重试

```json
{
  "request_id": "req_demo_error",
  "error": {
    "code": "validation_error",
    "message": "price 的值必须是十进制字符串或 null",
    "field": "fields.price.value",
    "retryable": false
  }
}
```

| HTTP | 含义 | 客户端处理 |
| --- | --- | --- |
| 400 | JSON 或基础请求格式错误 | 修正请求 |
| 401 | 无效/过期凭证 | 重新认证或轮换 |
| 403 | 已认证但无该操作权限 | 修改授权，不盲目重试 |
| 404 | 资源不存在或无资源访问权 | 检查目标/绑定 |
| 409 | 幂等或序号冲突 | 按具体错误修复 |
| 412 | 条件写入版本已变化 | 重新读取、人工确认合并 |
| 413 | 请求或最终推送体积超限 | 减少内容或调整接入方式 |
| 422 | 字段类型、版本、序列或目标不可用 | 按 field 修正 |
| 429 | 额度或速率限制 | 遵循 `Retry-After` |
| 503 | 临时不可用、不能完成持久提交 | 同一幂等键退避重试 |

超时可能发生在事务提交之后；发送方保留原幂等键重试。服务端不把未知结果当失败后另建重复消息。5xx 与网络失败可指数退避加随机抖动；不可重试错误不持续重放。APNs 错误由服务器任务处理，与 API 已接受状态分开记录。

## 11. 建议限额和保留策略

下表是默认建议参数，可根据实际自建部署环境调整，不构成平台吞吐保证。

| 项目 | 建议起始值/规则 |
| --- | --- |
| 消息 API 请求体 | 8 KiB 内，同时最终普通 APNs JSON payload 必须不超过 4096 字节；最终尺寸包含服务器字段 |
| 小组件状态请求体 | 路线 B 64 KiB 内；路线 A 必须连同包装符合 APNs 4096 字节上限 |
| 状态规模 | 每个作用域最多 32 字段，最多 20 项目，全状态最多 4 序列、每序列 60 点；同时受总体积限制 |
| 文本字段 | 每值最多 512 UTF-8 字节，label 最多 96 字节；通知正文仍受最终 APNs 体积限制 |
| 外部接入速率 | 每凭证每分钟 60 次写入、每用户 300 次，短时桶容量 10/30；按用户合并 Web 写入额度 |
| API 并发 | 每用户建议 4 个写请求，数据库按流串行更新 |
| 幂等结果 | 建议 24 小时，另有配额防止无限创建 |
| 消息历史 | 建议 30 天，公开可配置并允许本人主动删除 |
| 最新状态 | 保存至流删除；旧内容按业务时间显示过期，不以“永久最新”误导 |
| 分发/审计日志 | 建议 7 天详细、30 天摘要；不默认记录正文和 Authorization |
| 备份 | 建议每日备份、7 天滚动；删除数据在公开的备份保留期后清除 |

所有限额先验证再入库；不能写成功之后才发现所选传输路线无法承载。达到配额返回明确错误。计费或套餐尚未决定，不在本协议虚构可购买容量。

账号删除须清理活动资源、令牌、订阅和排队任务；离线设备可能保留缓存，下一次运行完成清理。系统通知列表与离线存储的清理能力按平台事实说明，不承诺远程瞬间抹除所有离线设备。

## 12. 协议验收要求

OpenAPI/JSON Schema、真实响应和手机解析器应共享同一版本定义；未知 schema_version 拒绝，不悄悄按旧版本解释。新增可选字段允许向前兼容，字段 key 语义变化按破坏性变更处理。

首要验收：两路独立、手动发送无需代码、重复和乱序不误覆盖、零与空值区分、字段别名保留、同数据多卡、跨用户隔离、断网后仍可读最近内容。实现边界见[实现概览](implementation.md)。
