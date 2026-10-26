# VaoPushCore

供 App、通知扩展与 Widget Extension 共用的 Swift Package。App 工程位于相邻的 `VaoPush/`，此包不包含 APNs 发送器或服务器。

## 已实现

- 通用数据字段、项目、折线/OHLC、快照和本地卡片模型。
- 字段类型、UTC 时间、数值字符串、空值、序列及版本校验。
- SQLite WAL、写事务、连接内串行访问；快照、卡片、交互状态、消息分表保存。
- 服务端 revision 防回退、重复识别、相同版本冲突拒绝。
- 以本地服务器连接与账号的组合隔离缓存；删除消息、卡片或来源分别处理。
- HTTPS 快照读取、Bearer 请求头、ETag/304、错误状态与目标数据校验。
- 消息/数据推送解析与分流、本地服务器/设备绑定检查、载荷体积限制。
- 多服务器配置、HTTPS 服务发现、SQLite v1→v2 迁移与组件来源标识兼容。
- iOS 条件代码中的 App Group 存储入口和 SwiftUI 卡片/Canvas 图表；明确标记的虚构演示数据。

原本地卡片支持根字段勾选、别名、顺序、小数位、模板与图表序列选择，以及保存、复制和删除。同时提供 Web 卡片描述校验、10类原生组件、发布版本合并与独立微调；网络更新和本机编辑通过SQLite事务合并，防止旧草稿回退发布版本或覆盖新微调。格式与限额见[工作台说明](../../docs/card-studio-api.md)。任意网页布局、自由脚本和微调云备份尚未交付。

调用者必须提供已登记绑定的连接与账号作用域；SQLite 的 owner 字段本身不是服务端鉴权。`account_demo` 保留给旧原型数据；多来源模拟显式标记为演示，真实通知接收默认拒绝演示绑定，没有生产登录。App 与扩展已接入相同 App Group；Keychain 凭证、推送 token 注册和生命周期仍由后续 iOS 集成负责。

## 本地验证

在此目录执行：

```sh
swift test
```

测试在 Mac 执行，HTTP 使用 URLProtocol 替身，不访问外部服务。测试覆盖并发连接、持久化、配置保留、字段格式、快照错误处理、多服务器隔离、消息卡片排序与推送环境判定。详见[实现概览](../../docs/implementation.md)。最低iOS deployment target为26.0；macOS13用于共享逻辑测试，不提供macOS产品。Mac核心使用Foundation、SQLite，iOS条件代码另使用SwiftUI；WidgetKit和App Intents在App/扩展层使用，无第三方依赖。
