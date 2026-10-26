# 客户端数据与隐私

适用 1.0.0 客户端。此文描述客户端与自建服务端之间的数据流转，公开隐私政策与支持说明见 [push.vaovao.app/privacy/](https://push.vaovao.app/privacy/)。

| 内容 | 当前处理 |
| --- | --- |
| 设备名称、绑定标识、通知/Widget 推送标识 | 发往用户添加的服务器，用于绑定、权限与投递 |
| 连接凭证 | 保存在系统钥匙串；App 控制与 Widget 只读凭证分开，不写入 SQLite 或日志 |
| 消息、卡片数据 | 从所选服务器同步，本机共享存储供 App 及扩展使用；业务 API 及其密钥留在上游/服务端 |
| 卡片微调和外观 | 本机保存；不自动写回 Web 模板或其他设备 |
| 示例 | 本机只读排版展示，无实时行情请求，不自动注册服务器或创建用户业务数据 |

客户端没有广告、分析 SDK 或跨应用跟踪功能。服务器由用户自行选择和部署，服务端对消息和设备记录的保留、删除及访问管理由对应服务器管理员控制，不能将“仅本机清理”视为远端服务器删除。

App 携带 `PrivacyInfo.xcprivacy`，声明自身 `UserDefaults` 用于语言、外观及连接状态（`CA92.1`）。启动耗时诊断仅在 Debug 编译，Release 不调用该处系统启动时间 API。声明依据 Apple 的[必需原因 API 说明](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)。

推送环境优先读取 App/扩展自身描述文件的 `aps-environment`；开发描述文件对应 Sandbox，生产描述文件对应 Production。缺少描述文件的 Release 分发默认 Production，Debug 默认 Sandbox；必要时可用 `VaoAPNsEnvironment` 配置。该逻辑不使用私有 Security API。

用户可以显式添加 HTTP 或 HTTPS 服务器。HTTPS 使用系统证书校验；HTTP 不会加密传输，连接凭据和业务内容可被网络观察者读取。App 在填写 HTTP 地址时提供简短说明，服务器选择与是否使用 TLS 由用户决定。语言偏好通过 App Group 共享给扩展，不上传服务端。

服务器移除首先尝试远端解绑。失败时本机资料保持，用户可明确选择强制删除本地配置；本机强制删除不会确认远端设备信息或推送标识已删除，仍可能收到该服务器发出的系统通知。
