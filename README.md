# Vao Push

[English](README_EN.md)

Vao Push 是一个免费、开源、支持自建部署的消息推送与桌面数据卡片系统。用户可以在自己的服务器部署服务端，在 iOS / iPadOS App 中连接服务器，再通过 HTTP、脚本、业务系统或 Web 控制台发送消息和更新结构化数据。

## 能力

- 系统通知：保存消息历史，并按设备发送通知；点击通知可直接打开对应消息详情。
- 桌面卡片：将数据源、最新状态和卡片布局分开管理，同一份数据可以被多张卡片使用。
- Web 工作台：创建数据源、配置字段、可视化设计卡片、导入 JSON 草稿、发布并生成订阅入口。
- AI 辅助设计：用户可以把不含密钥的生成说明交给自己选择的模型，再将返回的 JSON 草稿导入工作台。
- 自建部署：安装向导支持中文和 English、独立 API/Web 端口、IP HTTP、域名 HTTPS、反向代理和自带证书。

## 当前版本

服务端 1.0.0 提供 Linux amd64 / arm64 预构建安装包，安装时自动配置官方客户端的 Production APNs。客户端 1.0.0 已提交 App Store 审核，公开官网与支持文档见 [push.vaovao.app](https://push.vaovao.app)。源码不含 Apple 私钥或用户部署凭证。桌面小组件刷新由系统调度和推送条件共同决定，不承诺固定每分钟刷新。

[下载服务端 1.0.0](https://github.com/loewe1631/Vao-Push/releases/tag/v1.0.0) · [安装指南](deploy/PUBLIC-INSTALL.md) · [官网与支持](https://push.vaovao.app)

## 快速入口

- [简单接入](docs/simple-onboarding.md)
- [API 协议](docs/api-v1.md)
- [卡片工作台](docs/card-studio-api.md)
- [Web 创建指南](docs/web-studio-guide.md)
- [服务端安装](deploy/PUBLIC-INSTALL.md)
- [数据与隐私](docs/privacy-data-flow.md)
- [第三方依赖与许可](THIRD_PARTY.md)

## 目录

```text
ios/        iOS App、通知扩展、Widget 和共享核心
server/     Go 服务端、PostgreSQL schema 与发送 worker
web/        Vue 3 / TypeScript Web 控制台
deploy/     安装、升级、备份和恢复工具
docs/       API、卡片和部署文档
examples/   不含真实凭证的请求与卡片示例
```

## 开发验证

服务端：

```sh
cd server
go test -race ./...
go vet ./...
```

Web：

```sh
cd web
npm ci
npm test
npm run build
```

iOS 共享核心：

```sh
cd ios/VaoPushCore
swift test
```

## 许可证

本项目主许可证为 MIT。第三方依赖和素材的许可记录见 [THIRD_PARTY.md](THIRD_PARTY.md) 与 [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt)。
