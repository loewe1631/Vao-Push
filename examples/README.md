# 请求示例

所有内容均为虚构示例数据，不包含真实凭证。

| 文件 | 用途 |
| --- | --- |
| [task-complete.json](notifications/task-complete.json) | 提交一条任务完成通知 |
| [progress.json](widgets/progress.json) | 替换任务进度卡片的数据状态 |
| [quote.json](widgets/quote.json) | 虚构行情字段与两根 OHLC 蜡烛 |
| [cards/market-design.json](cards/market-design.json) | 列表型卡片布局示例 |
| [cards/task-data.json](cards/task-data.json) | 任务进度示例数据 |
| [cards/task-design.json](cards/task-design.json) | 任务进度卡片布局示例 |

通知使用 `POST /v1/push/{key}` 或 `POST /v1/messages`，卡片数据源使用 `PUT /v1/card-data/{source_key}` 或 `PUT /v1/widgets/{data_id}/state`。字段类型、空值、百分比和幂等规则见 [接口协议](../docs/api-v1.md)。
