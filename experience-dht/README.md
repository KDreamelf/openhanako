# experience-dht

`experience-dht` 是经验网络的独立 DHT / rendezvous / relay 协调端 MVP。

它不嵌入 `ph01-experience-hub`，不依赖 `ph01-deploy`。源码留在当前目录；对外发放的是 `deployment-package/` 或 `release/` 里的压缩包。

## 配置原则

部署配置必须尽量少。`config.yml` 只保留：

- `listen`
- `init_password`

Docker Hub 镜像部署时可以不挂载配置文件，直接用环境变量传入首次绑定密码：

> 已经加入官方DHT的初始化密码，勿覆盖

```bash
docker run -d \
  --name experience-dht \
  --restart unless-stopped \
  --label com.centurylinklabs.watchtower.enable=true \
  -e EXPERIENCE_DHT_INIT_PASSWORD='dOHtMbUPd3qRMBYX' \
  -p 8091:8091 \
  -p 41001:41001/udp \
  -p 41002:41002/udp \
  -v experience-dht-data:/data/experience-dht \
  dreamelf6174/experience-dht:latest
```

节点 ID 首次启动自动生成并写入状态文件。状态路径不从配置文件读取：Docker 内部固定使用 `/data/experience-dht/state.json`，上面的最简命令用命名卷 `experience-dht-data` 持久化；本地调试默认使用 `./data/experience-dht/state.json`。公网访问 URL、QUIC/UDP 候选地址、管理端地址、relay 策略、公开状态都由绑定后的客户端配置面板签名写入 DHT。

端口约定：

- TCP `8091`：HTTP API、绑定、状态查询、relay、hole-punch 控制面。
- UDP `41001`：传统 UDP 候选端点，DHT 会响应该端口上的轻量 `healthz` 探测；客户端用它做 IPv4 打洞候选。
- UDP `41002`：QUIC 候选端点，客户端优先探测；失败后降级 UDP，再使用 HTTP API/relay。

需要重新初始化/重新绑定时，清理命名卷 `experience-dht-data` 或 Compose 的 `data/` 后重建；部署包提供 `deploy.sh reset` / `deploy.ps1 reset`。

正常更新不能删除持久化状态。推荐用 Watchtower 自动更新带标签的 DHT 容器：

```bash
docker run -d \
  --name experience-dht-watchtower \
  --restart unless-stopped \
  -v /var/run/docker.sock:/var/run/docker.sock \
  containrrr/watchtower \
  --label-enable \
  --cleanup \
  --interval 3600
```

`latest` 标签不会让容器自动更新；Watchtower 会按原容器配置重建并保留命名卷。不要使用 `--remove-volumes`，也不要删除 `experience-dht-data`，否则绑定公钥和客户端下发配置都会丢失。

如果版本升级新增了宿主机端口映射，例如新增 UDP `41002`，Watchtower 不能自动把这个端口加到旧容器配置里。此时必须手动删除旧容器并用新的 `docker run` 参数重建，但继续挂载同一个 `experience-dht-data` 命名卷。这样会更新镜像和端口映射，同时保留节点 ID、绑定公钥、公开状态和客户端下发的运行配置。

## 当前 API

- 健康检查：`GET /healthz`
- 首次绑定：`POST /api/v1/admin/bind`
- 管理状态：`POST /api/v1/admin/status`
- 同步运行配置：`POST /api/v1/admin/config`
- 更新 bootstrap 管理端：`POST /api/v1/admin/bootstrap`
- 开启/关闭公共注册：`POST /api/v1/admin/public`
- 短 TTL presence：`POST /api/v1/peers/presence`
- provider 查询：`GET /api/v1/providers?package_hash=sha256:...`
- 包请求/offer：`/api/v1/package-requests...`
- federation 查询：`/api/v1/federation/...`
- 打洞协调：`/api/v1/hole-punch/sessions...`
- relay：`/api/v1/relay/sessions...`

绑定后，管理请求必须使用绑定账号公钥按 PH01 `SignedRequest` 签名。

## 构建部署包

Linux / macOS：

```bash
cd experience-dht
./scripts/build-deployment-package.sh 20260512
```

Windows / PowerShell：

```powershell
cd experience-dht
.\scripts\build-deployment-package.ps1 -Version 20260512
```

构建脚本会测试、编译 Linux `amd64` 二进制，并生成可发放压缩包。部署包不包含 Go 源码。

## 发布 Docker Hub 镜像

```bash
cd experience-dht
./scripts/build-deployment-package.sh 20260512
./scripts/publish-docker-image.sh 20260512
```

默认仓库是 `dreamelf6174/experience-dht`，脚本会构建 `dreamelf6174/experience-dht:20260512` 和 `dreamelf6174/experience-dht:latest` 并推送。镜像只复制部署包里的 `bin/experience-dht`，不包含 Go 源码。

## 本地调试

```bash
cd experience-dht
go run ./cmd/experience-dht -config config.yml
```

## 验证

```bash
go test ./...
go vet ./...
```
