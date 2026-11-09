# Vao Push 安装与升级 / Installation and Upgrades

服务端1.2.0提供Linux amd64、arm64预构建包，使用Python 3、systemd和Docker，不要求安装Go或Node。

## 首次安装 / New installation

```sh
curl -fsSL https://github.com/loewe1631/Vao-Push/releases/download/v1.2.0/install.sh -o vao-push-install.sh
sudo bash vao-push-install.sh
```

安装向导默认中文、API端口8188、Web端口18188、管理员`admin`与随机24位初始密码。支持IP直连HTTP、自动域名HTTPS、已有HTTPS反代和自带证书；数据库只监听回环。安装器不会自动修改防火墙，需开放实际使用的API/Web端口；自动HTTPS还需满足域名验证条件。

Official packages configure the product's production APNs identity and signed Web updater during installation. The installer supports Chinese/English, configurable API/Web ports and multiple HTTP/HTTPS deployment modes. Open only the required public ports; keep PostgreSQL private.

## 已安装用户：无需重装 / Existing users: no reinstall

```sh
curl -fsSL https://github.com/loewe1631/Vao-Push/releases/download/v1.2.0/install.sh -o vao-push-install.sh
sudo bash vao-push-install.sh --upgrade --prefix /opt/vao-push
```

这是原地升级，不会重新初始化数据库，也不会重置密码、域名、端口、设备、推送地址或已有APNs身份。自定义安装位置请修改`--prefix`。安装包下载与校验后自动备份、切换程序、验证健康及实际运行版本，并补齐Web更新执行器。

Run this once for installations created before Web updates were available. It preserves existing data and configuration and enables future updates from the Web page. Do not uninstall, delete the database, or create another installation over the same data.

## Web更新

升级后进入“服务器设置 → 系统更新”，点击“检查更新”，阅读说明后确认升级。正式更新源使用独立签名，包摘要、架构、升级路径和旧App兼容要求均受检。下载或备份失败不切换程序；关闭页面不会取消已受理任务，服务重启后页面重连。默认不会定时静默安装。

The Web service submits a structured request to a separate instance-bound local executor. It does not receive arbitrary root-command access. A running executor is not restarted in the middle of its own upgrade. Custom operator feeds and pinned keys are retained across upgrades; operators remain responsible for their custom trust configuration.

若使用源码或自定义部署而未带官方更新配置，页面会说明缺失条件。可由管理员使用安装包内`install-update-agent.py --root <安装目录>`补齐；官方包内已带更新源与公钥，普通用户无需填写这些字段。

## 管理与备份

```sh
sudo python3 /opt/vao-push/current/manage.py --root /opt/vao-push status
sudo python3 /opt/vao-push/current/manage.py --root /opt/vao-push logs
sudo python3 /opt/vao-push/current/manage.py --root /opt/vao-push backup
sudo python3 /opt/vao-push/current/manage.py --root /opt/vao-push restore-check /path/to/database.dump
```

升级前备份数据库、部署配置和身份。健康失败时回退兼容的旧程序，并再次检查健康；**不会自动逆转数据库迁移**。自动升级仅提供声明数据回退兼容的路径，破坏性迁移需另行安排。备份包含解密主密钥和凭据，须保持私有并复制到独立加密存储；同盘副本不是灾难恢复保证。`restore-check`仅操作随机测试库，不覆盖运行库。

Program rollback is not database rollback. Backups contain secrets. Protect them and retain a copy outside the server. A restore check uses a disposable database only.

## 客户端兼容与推送身份

服务端1.2.0保留App 1.0.0 / 1.1.0的已有功能；新卡片能力需App 1.2.0。手机App通过App Store更新，Web不会代替商店安装手机软件。

官方预构建安装包附带本产品专用Production APNs身份，普通用户无需填写苹果Key ID、Team ID或私钥。源码不包含该私钥；已有人工配置在升级时保留，不因普通升级轮换。

The server package includes only this product's dedicated production push identity. Source control, examples and update manifests do not contain its private key. Update-manifest signing uses a separate private key that is never distributed.

## 发布包构建

维护者先构建Web和对应架构Go程序，再使用`deploy/package-release.py`。正式包需要主许可证、第三方许可、本产品生产推送身份和更新公钥/配置；`--candidate`只用于不附生产身份的隔离验证包。打包与签名工具不会自行上传或发布。


### 1.1.0 维护包原地刷新

已安装早期 1.1.0 时，可再次运行正式安装器的 `--upgrade --prefix <安装目录>`。不同内容会保存到独立目录，原程序及数据保留，并执行备份和健康检查；重复运行完全相同的包不会重新切换。旧版 Web 更新器只比较版本号，同版本维护包请使用此命令刷新。不要手动覆盖正在运行的 releases 目录。

For an earlier 1.1.0 installation, rerun the official installer with `--upgrade --prefix <installation>`. The refreshed package uses a separate content directory with backup and health checks. Repeating the identical package is a no-op. Older Web updaters compare version numbers and do not offer same-version maintenance rebuilds.

## 1.2.0 card compatibility / 卡片兼容

New card features require App 1.2.0; App 1.0/1.1 receives the saved compatible layouts. Existing bindings, messages and card adjustments remain. After saving a v3 design, rolling back to a server before 1.2 requires the matching pre-upgrade database backup as well as the old program. A program-only rollback cannot interpret v3 designs.

新卡片能力需 App 1.2.0；旧 App 使用保存的兼容布局。写入 v3 设计后若退回旧于 1.2 的服务端，须配合相应升级前数据库备份，不能仅替换程序。正式升级前应保留备份和恢复窗口。
