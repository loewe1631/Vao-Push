# 第三方依赖

本项目源代码采用 MIT License。第三方依赖与资源遵循各自的许可证。

服务端直接依赖 pgx/v5（MIT）与 golang.org/x/crypto 的 bcrypt（BSD-3-Clause）；间接依赖许可见各模块随附 LICENSE 和 go.sum 固定版本。Go 标准库使用 Go 项目 BSD 风格许可。

Web 直接依赖 Vue（MIT）；构建依赖 Vite、@vitejs/plugin-vue、TypeScript、vue-tsc 及其锁定的传递依赖，各自保留上游许可。TypeScript 为 Apache-2.0，其余直接构建依赖为 MIT。分发源码、Web产物和安装包前需汇总实际锁定依赖的版权/许可文本。

iOS 使用 Apple 系统框架和自有共享代码，无第三方 Swift 包。Apple SDK 条款不由本项目重新授权。

部署用 PostgreSQL、Docker 与 Caddy 属独立运维组件；生产分发或打包这些组件前按实际版本保留相应许可。本仓库不携带这些可执行文件、私钥、数据库或私有部署配置。

关于页GitHub图标取自[Simple Icons的GitHub SVG](https://github.com/simple-icons/simple-icons/blob/develop/icons/github.svg)（SHA256 `3bf8cceead820aec50d4ee825a3fd02c5a1cd6665cc9cf4cbf3d9c8861a204bb`），按[CC0-1.0](https://github.com/simple-icons/simple-icons/blob/develop/LICENSE.md)提供。GitHub名称及标志为GitHub商标；此处仅用于链接本产品代码仓库，不表示GitHub背书。官网图标使用Apple系统globe符号。
