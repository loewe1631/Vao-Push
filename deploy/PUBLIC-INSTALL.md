# Vao Push 服务端安装 / Server Installation

服务端 1.0.0 为正式公开版，提供 Linux amd64 / arm64 安装包，安装时自动配置官方客户端的生产推送身份。源码不包含推送私钥；官方预构建服务端安装包在发布步骤中附带本产品推送身份。

Server 1.0.0 is the public release for Linux amd64 and arm64. Official packages configure production APNs automatically. Private keys are supplied during release packaging and are absent from source control.

## 环境 / Requirements

Linux amd64 或 arm64、systemd、Python 3、Docker Engine；确保所选端口可从设备访问。默认服务端口 8188、Web 端口 18188，数据库仅监听本机自动选择的内部端口。已有其他服务时不会占用 443，也不会停止原服务。

Linux amd64 or arm64 with systemd, Python 3, and Docker Engine. The default public API port is 8188 and Web port is 18188. PostgreSQL is published on loopback only.

## 安装 / Install

下载安装器并执行，脚本会按 CPU 架构下载 1.0.0 正式包并核对 SHA256：

```sh
curl -fsSL https://github.com/loewe1631/Vao-Push/releases/download/v1.0.0/install.sh -o vao-push-install.sh
sudo bash vao-push-install.sh
```

Download and run the installer above. It selects the architecture and verifies the package checksum.

也可以从 [GitHub Releases](https://github.com/loewe1631/Vao-Push/releases/tag/v1.0.0) 下载并解压对应架构的安装包，然后在解压目录执行：

```sh
sudo bash install.sh
```

安装向导依次选择语言（默认中文）、API 端口（8188）、Web 端口（18188）、管理员（`admin`）、密码（默认随机 24 位）、访问方式（默认 HTTP 的 IP 直连）和公网 IP 或域名（默认自动探测）。初始密码可在 Web 设置修改。安装完成后显示 App 及 Web 地址、账号和首次密码。初始密码不会在升级时重置。

Run the installer from an extracted prebuilt bundle. Press Enter to accept defaults. Change the generated password later in Web Settings. Upgrades preserve the existing password, server identity, encryption key, and data.

HTTP 直连无需域名或 Cloudflare；登录、凭据和内容通过明文 HTTP 传输。有域名可以选择自动 HTTPS，安装程序生成 Caddy 配置并由 Caddy 申请及续期证书；需要域名正确解析、80 端口可用于 ACME 验证且未被其他服务占用。自定义 HTTPS 服务端口不改变 ACME 验证条件。也可使用现有反向代理或自带证书。已有代理方式会把本项目服务绑定在回环地址，Web 代理需同时转发同源 `/v1/` 接口。

HTTP works with an IP address and needs no domain or Cloudflare. It does not encrypt transport. Automatic HTTPS uses Caddy and requires a domain and reachable ACME validation. Existing HTTPS proxies and operator-provided certificates are also supported.

安装程序不关闭防火墙。若 VPS 提供商有安全组或启用了 UFW，请放行所选 API/Web TCP 端口；自动 HTTPS 还需要 80 端口。生产数据库端口不要对外开放。

The installer does not disable firewalls. Allow the chosen API and Web TCP ports in the VPS firewall/security group. Automatic HTTPS also needs port 80. Do not expose PostgreSQL publicly.

若安装中断，配置与数据会保留。修复依赖后可续装，保持配置目录私有，并再次显示原地址、账号和初始密码：

```sh
sudo bash install.sh --resume
```

## 管理 / Management

```sh
sudo python3 /opt/vao-push/current/manage.py status
sudo python3 /opt/vao-push/current/manage.py restart
sudo python3 /opt/vao-push/current/manage.py logs
sudo python3 /opt/vao-push/current/manage.py backup
sudo python3 /opt/vao-push/current/manage.py restore-check /path/to/database.dump
sudo python3 /opt/vao-push/current/manage.py upgrade /path/to/extracted-new-bundle
```

升级先备份，再切换程序版本；启动健康检查失败时恢复原程序。数据库迁移不会被自动逆转；跨版本恢复需要相应私有备份。备份包含数据库、实例身份、解密主密钥和凭据，须复制到独立加密存储。同盘副本不是灾难恢复保证。恢复检查只创建并清理随机测试库，不覆盖运行库。

An upgrade first creates a backup, then switches the program. A failed health check restores the previous program; it does not reverse database migrations. Backups contain secrets and must be protected and copied to independent encrypted storage. A restore check uses a disposable database only.

## 制作发布包 / Build a Package

先构建 Web 并交叉编译 Go，然后运行 `deploy/package-release.py`。包只含预构建程序、Web 静态文件及安装/管理工具，不要求最终用户安装 Go 或 Node。`--candidate` 用于不含生产身份的本地验证包；正式打包必须包含 `LICENSE`、完整依赖许可及生产身份文件。打包工具不会上传 GitHub、CI、镜像仓库或商店。

```sh
python3 deploy/package-release.py --version 1.0.0 --arch amd64 \
  --binary /path/to/linux-amd64/vao-push --web web/dist \
  --out /path/to/private-artifacts --candidate
```

正式身份文件由维护者在发布准备时提供，声明 `environment=production` 及产品 topic；安装器只把身份写入私有配置，服务首次启动加密导入数据库。升级到含身份的正式包时，如果旧安装尚未配置推送身份，管理工具会自动导入包内身份；已有人工配置始终保留，不会被覆盖。后续兼容的客户端更新通常无需重装服务端。

The maintainer supplies the production identity with `environment=production` and the product topic. The installer keeps it in private configuration and the service imports it into the encrypted database on first start. When upgrading an installation that has no APNs identity yet, the management tool imports the identity from a package that contains one; an operator-configured identity is always preserved. The source tree never contains the private key.
