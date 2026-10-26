# iOS / iPadOS 客户端

客户端由 SwiftUI App、通知服务扩展、Widget Extension 和共享的 `VaoPushCore` Swift Package 组成。

## 能力

- 添加多个自建服务器并分别管理连接；
- 查看消息历史，点击系统通知直接进入对应消息详情；
- 导入 Web 发布的卡片并进行轻量本机微调；
- 使用 App Group 共享本地状态和 Widget 数据；
- 中文、English、跟随系统和明暗主题；
- 支持普通消息通知和结构化 Widget 更新协议。

Bundle ID、App Group 和 APNs 环境由维护者在 Xcode 的签名配置中提供。公开源码不包含 Apple 账号、描述文件、私钥或设备资料。

## 共享核心测试

```sh
cd VaoPushCore
swift test
```

Widget 刷新时间由系统预算和设备状态决定，客户端不承诺固定每分钟更新。
