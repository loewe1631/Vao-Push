# Vao Push 服务端

Go + PostgreSQL 的单节点服务，内含持久 outbox Worker，接受任意工具的合法请求。Web 手动操作与外部发送请求复用校验、事务保存及分发逻辑。

已实现两路接收、快照/ETag、自动设备注册与专属 Key、Web多选消息、保存默认接收列表及统一消息地址、首次状态自动创建、游标同步、关注关系、范围控制、暂停/解绑、Web会话/CSRF、APNs身份加密保存及HTTP/2发送。没有配置苹果身份或设备token时任务显示blocked，不会伪造投递成功。

支持独立卡片数据源、受控公网HTTPS JSON采集与字段映射、Web草稿/发布、订阅码和设备读取授权。原有外部上报保留；业务阈值仍由上游决定。共享源不通过旧设备作用域自动公开，读取与消息默认接收列表分别授权。使用方法、接口及限额见[卡片工作台](../docs/card-studio-api.md)。

需要 Go 1.27+、PostgreSQL 16+。先构建 Web，按 [部署说明](../deploy/README.md) 创建私有配置，然后运行：

```sh
go mod download
go build -trimpath -o bin/vao-push .
VAO_CONFIG=/srv/vao-push/run/config.json ./bin/vao-push
```

启动时执行内嵌、可重复的建表迁移；仅当 users 为空时创建 bootstrap 管理员。随机初始化密码至少20字节；之后可在 Web 更新密码。配置文件与数据库备份必须私有，不能提交。

集成测试通过 VAO_TEST_CONFIG 提供数据库连接；每个测试创建独立随机 schema，结束只清理该 schema，不复用业务表：

```sh
VAO_TEST_CONFIG=/srv/vao-push/run/config.json go test -race -count=1 ./...
go vet ./...
```

协议见 [API](../docs/api-v1.md) 与 [当前实现](../docs/implementation.md)。真实 APNs 与 WidgetKit 后台行为仍需签名和真机验证。Web 账号仅用于服务器管理，手机无需登录或配对；旧 API 兼容保留。公开多租户账号服务后移。接入见 [简单接入](../docs/simple-onboarding.md)。

客户端注册时填写设备显示名，设备控制凭据可改名；同步返回当前名称。名称不承担认证，稳定设备标识及凭据不因改名而改变，默认接收列表按标识保存。
