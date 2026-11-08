# Vao Push

[English](README_EN.md)

Vao Push 是免费、开源、支持自建部署的消息推送与桌面数据卡片系统。在自己的服务器部署服务端，在 iOS / iPadOS App 中连接后，即可通过 HTTP、脚本、业务系统或 Web 控制台发送消息和更新数据。

## 服务端 1.1.0

- **多推送列表**：按用途保存多个接收设备列表，每个列表有独立地址；支持改名、修改设备和删除。原默认发送地址继续可用。
- **多尺寸卡片布局**：同一卡片、同一数据源可发布不同尺寸的布局；Web 提供独立编辑、固定画布和溢出提示。旧 App 继续读取默认布局。
- **消息图标参数**：API 和 Web 可逐条指定 HTTPS 图标地址；支持该能力的客户端显示对应头像，旧客户端继续显示原文字通知。
- **Web 系统更新**：标准安装和原地升级自动配置签名更新源及独立执行器；以后可在服务器设置检查更新并确认升级。
- **保留旧客户端兼容**：服务端升级保留账号、设备绑定、推送地址、历史、数据源和卡片订阅，App 1.0.0 的已有功能可继续使用。

本次发布服务端和 Web，不代表同时发布了新版 iOS App。多尺寸原生呈现与通知图标需要支持这些能力的客户端；手机更新通过 App Store 完成。

[下载服务端 1.1.0](https://github.com/loewe1631/Vao-Push/releases/tag/v1.1.0) · [安装与升级](deploy/PUBLIC-INSTALL.md) · [官网与支持](https://push.vaovao.app)

## 首次安装

```sh
curl -fsSL https://github.com/loewe1631/Vao-Push/releases/download/v1.1.0/install.sh -o vao-push-install.sh
sudo bash vao-push-install.sh
```

## 已安装用户升级

**无需重新安装或清空数据。** 执行一次原地升级，保留原配置、密码、设备、地址和数据，并补齐 Web 更新功能：

```sh
curl -fsSL https://github.com/loewe1631/Vao-Push/releases/download/v1.1.0/install.sh -o vao-push-install.sh
sudo bash vao-push-install.sh --upgrade --prefix /opt/vao-push
```

自定义安装位置请修改 `--prefix`。升级前自动备份，切换后验证服务健康与实际版本；程序回退与数据库恢复的边界见[安装指南](deploy/PUBLIC-INSTALL.md)。后续在 Web「服务器设置 → 系统更新」操作即可，默认不会定时静默安装。

## 其他能力

- 消息历史与通知点击直达详情、多服务器隔离、任意多选设备手动发送。
- JSON/API 数据源、字段映射、可视化卡片设计、JSON 导入、发布与订阅码。
- AI 辅助设计：将不含密钥的说明交给用户选择的模型，再导入返回的布局 JSON。
- 中文 / English、明暗外观；安装支持独立 API/Web 端口、IP HTTP、域名 HTTPS、反向代理和自带证书。

源码不包含 Apple 私钥或客户部署凭据。官方预构建安装包按产品部署方式附带本产品专用 Production APNs 身份；更新清单使用单独的签名密钥，源码和安装包只包含其公钥。Widget 刷新由系统调度和推送条件共同决定，不承诺固定每分钟刷新。

## 文档

- [1.1.0 功能与兼容规则](docs/server-1.1.md)
- [简单接入](docs/simple-onboarding.md) · [API 协议](docs/api-v1.md) · [OpenAPI](docs/openapi.json)
- [卡片工作台](docs/card-studio-api.md) · [Web 创建指南](docs/web-studio-guide.md)
- [数据与隐私](docs/privacy-data-flow.md) · [第三方依赖](THIRD_PARTY.md)

## 目录与开发验证

`ios/` 为 App、扩展与共享核心；`server/` 为 Go/PostgreSQL 后端；`web/` 为 Vue 控制台；`deploy/` 为安装升级工具；`docs/` 和 `examples/` 提供协议与无真实凭据的示例。

```sh
cd server && go test -race ./... && go vet ./...
cd ../web && npm ci && npm test && npm run build
cd ../ios/VaoPushCore && swift test
```

服务端集成测试使用 `VAO_TEST_CONFIG` 指定独立数据库配置，每例创建随机 schema；不要将生产库作为测试配置。可选网络测试须显式提供各自的隔离环境。

## 许可证

本项目主许可证为 MIT。第三方依赖和素材的许可记录见 [THIRD_PARTY.md](THIRD_PARTY.md) 与 [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt)。
