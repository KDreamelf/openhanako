# experience-dht 独立部署包

这个目录是对外扩散用的部署包目录，不是源码目录。发布方只需要发这个目录或 release 压缩包。

## 包内容

- `bin/experience-dht`：开发机构建出的 Linux 可执行文件。
- `config.yml`：可选极简配置；Docker Hub 部署默认不需要挂载配置文件。
- `Dockerfile`：开发机发布镜像时使用，只复制预编译二进制，不包含源码。
- `docker-compose.yml`：默认使用 `dreamelf6174/experience-dht:latest`。
- `deploy.sh` / `deploy.ps1`：部署和重置脚本。

## 最简 Docker 部署

只需要设置一次性绑定密码：

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

这个命令使用命名卷 `experience-dht-data` 保存节点 ID、绑定公钥和客户端下发的运行配置。升级镜像时必须保留这个卷，不能带 `--remove-volumes`，也不要删除 `experience-dht-data`。

## Compose 部署

Linux：

```bash
export EXPERIENCE_DHT_INIT_PASSWORD='换成强密码'
./deploy.sh init
./deploy.sh up
```

Windows / PowerShell：

```powershell
$env:EXPERIENCE_DHT_INIT_PASSWORD = "换成强密码"
.\deploy.ps1 init
.\deploy.ps1 up
```

`up` 会检查 `EXPERIENCE_DHT_INIT_PASSWORD`；没设置首次绑定密码会拒绝启动。这个密码只用于第一次绑定账号公钥，绑定后日常管理走客户端签名。

## 状态文件

DHT 状态路径不需要、也不允许由部署方填写。容器内状态路径由程序固定为 `/data/experience-dht/state.json`。

用上面的最简命令部署时，宿主机数据由 Docker 命名卷 `experience-dht-data` 托管。用 Compose 部署时，宿主机路径由 `docker-compose.yml` 的 volume 映射决定：

```yaml
${EXPERIENCE_DHT_DATA_DIR:-./data}:/data/experience-dht
```

所以 Compose 默认实际落在宿主机部署包目录下的 `data/state.json`。如果设置 `EXPERIENCE_DHT_DATA_DIR=/opt/experience-dht/data`，实际宿主机文件就是 `/opt/experience-dht/data/state.json`。部署方只需要理解宿主机 `data/` 或命名卷会被持久化，不需要接触容器内部路径。

## 客户端绑定

1. 在客户端 DHT 配置里填写 DHT 公网访问 URL，例如 `http://服务器IP:8091` 或 `https://dht.example.com`。
2. 在客户端勾选候选端点：QUIC 填 `服务器IP:41002`，传统 UDP 填 `服务器IP:41001`。两者可以同时启用，客户端会优先探测 QUIC，再降级 UDP，最后使用 HTTP API/relay。
3. 用 `EXPERIENCE_DHT_INIT_PASSWORD` 设置的一次性密码绑定当前账号公钥。
4. 绑定后，管理端地址、公开注册、relay 策略、公网 URL、QUIC/UDP 地址都由客户端配置面板签名同步到 DHT。

DHT 默认私有，不会因为启动就注册到经验网络管理端。公开注册必须由绑定客户端开启。

## 重置重绑

DHT 不存经验包数据。需要重新初始化或换绑账号时，直接清理状态重建：

Docker 命名卷部署：

```bash
docker rm -f experience-dht
docker volume rm experience-dht-data
```

Linux：

```bash
./deploy.sh reset
./deploy.sh up
```

Windows / PowerShell：

```powershell
.\deploy.ps1 reset
.\deploy.ps1 up
```

`reset` 会删除 `data/`，节点 ID、绑定公钥、客户端下发配置和公开状态都会重新生成。重建后重新用 `EXPERIENCE_DHT_INIT_PASSWORD` 对应的一次性密码绑定即可。

## 端口

- TCP `8091`：DHT HTTP API，客户端用它绑定、探测、同步配置、presence、relay、hole-punch。
- UDP `41001`：传统 UDP 候选端点，DHT 会响应该端口上的轻量 `healthz` 探测；客户端用它做 IPv4 打洞候选。是否使用由客户端配置面板同步。
- UDP `41002`：QUIC 候选端点，优先连接；如果 QUIC 协商失败，客户端降级到传统 UDP，再使用 HTTP API/relay。

常用环境变量：

- `EXPERIENCE_DHT_HTTP_PORT`：宿主机 HTTP 端口，默认 `8091`。
- `EXPERIENCE_DHT_PUBLIC_PORT`：宿主机 UDP 端口，默认 `41001`。
- `EXPERIENCE_DHT_QUIC_PORT`：宿主机 QUIC UDP 端口，默认 `41002`。
- `EXPERIENCE_DHT_BIND_ADDR`：端口绑定地址。
- `EXPERIENCE_DHT_IMAGE`：镜像名，默认 `dreamelf6174/experience-dht:latest`。
- `EXPERIENCE_DHT_INIT_PASSWORD`：首次绑定密码，必填。

## 更新

`latest` 标签不会让容器自动更新；需要重建容器或使用 Watchtower。只要保留 `experience-dht-data` 命名卷或 Compose 的 `data/` 映射，已经初始化并绑定的管理权不会丢失。

Watchtower 适合“镜像内容变了，但容器创建参数没变”的更新。它会用原容器配置重建容器，所以不能自动新增端口映射。如果版本升级新增了宿主机端口，例如新增 UDP `41002`，需要手动重建一次 DHT 容器：

```bash
docker pull dreamelf6174/experience-dht:latest
docker rm -f experience-dht
docker run -d \
  --name experience-dht \
  --restart unless-stopped \
  --label com.centurylinklabs.watchtower.enable=true \
  -e EXPERIENCE_DHT_INIT_PASSWORD='原来的一次性绑定密码或任意非空强密码' \
  -p 8091:8091 \
  -p 41001:41001/udp \
  -p 41002:41002/udp \
  -v experience-dht-data:/data/experience-dht \
  dreamelf6174/experience-dht:latest
```

关键点是不能删除 `experience-dht-data`，也不能使用 `--remove-volumes`。已绑定状态存在卷里，重建容器不会破坏绑定关系；`EXPERIENCE_DHT_INIT_PASSWORD` 在已有状态下不会重新绑定，只是满足启动配置要求。

推荐部署 Watchtower 自动更新带标签的 DHT 容器：

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

如果只想手动更新一次：

```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  containrrr/watchtower \
  --run-once \
  --cleanup \
  experience-dht
```

Compose 部署也可以直接拉新镜像并重建服务，保留 `data/`：

```bash
./deploy.sh pull
./deploy.sh up
```

源码更新后不要在服务器编译。开发机重新构建并发布 Docker Hub 镜像；服务器只拉取 `dreamelf6174/experience-dht`。
