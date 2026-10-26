# 服务端部署工具

`deploy/` 包含 Linux 安装、升级、备份、恢复检查和发布包制作工具。正式包面向 Linux amd64/arm64，用户不需要安装 Go 或 Node。

## 安装默认值

安装向导提供中文和 English，默认 API 端口 8188、Web 端口 18188、管理员 `admin`、随机 24 位初始密码。访问方式支持：

1. IP 直连 HTTP；
2. 域名自动 HTTPS；
3. 已有 HTTPS 反向代理；
4. 用户提供 HTTPS 证书。

安装器不会自动修改防火墙。用户需要在 VPS 安全组或 UFW 中开放实际使用的 API/Web TCP 端口；自动 HTTPS 还需要 ACME 验证所需的端口。PostgreSQL 只应监听回环地址。

## 凭证边界

正式安装包由维护者在私有发布环境中附带 `app.vaovao.push` 的生产 APNs 身份。安装器把身份写入私有目录，服务首次启动后加密导入数据库。Web 不要求普通用户填写 Key ID、Team ID、Bundle ID 或 `.p8` 私钥。源码和示例不包含真实凭证；官方预构建安装包附带本产品专用推送身份。

升级会先备份，再切换程序并运行健康检查；失败时恢复旧程序。升级到含 APNs 身份的包时，只有旧安装尚未配置身份且不存在歧义文件时才会自动导入；已有人工配置永远保留。

## 本地制作验证包

```sh
python3 deploy/package-release.py \
  --version 1.0.0 \
  --arch amd64 \
  --binary /path/to/vao-push \
  --web web/dist \
  --out /path/to/private-artifacts \
  --candidate
```

正式包需要主许可证、第三方许可文本和生产 APNs 身份文件。发布工具不会上传 GitHub、Cloudflare、镜像仓库或 App Store。
