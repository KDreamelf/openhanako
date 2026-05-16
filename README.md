# PH01 workspace

PH01 的多端工作区——按用途分到子目录，互不干扰。客户端 UI 与 PH01 身份、经验网络、Windows 操作链为本项目重构实现；底层 Agent 执行引擎逻辑改为引入 OpenAI Codex（Apache-2.0）。

命名约定：`ph01-*` 只用于正式生产组件；历史实现、原型和迁移期参考目录统一使用 `legacy-*`。

## 目录结构

```
ph01-workspace/
├── flutter-migration-plan/   # 迁移方案文档（7 份 markdown + 性能优化复盘 + pubspec 模板）
├── legacy-electron/          # 原 Electron + Node.js 实现（保留参考，不改动）
├── hanako-flutter/           # PH01 Flutter 子体客户端；Agent 执行引擎逻辑引入 OpenAI Codex
├── openai-codex/             # OpenAI Codex 源码归档与引擎逻辑参考，保留 LICENSE / NOTICE
├── ph01-backend/             # 认证中心 / 授权中心（auth-center，PostgreSQL + Redis + HCL）
├── ph01-ai-gateway/          # AI 网关，魔改 New API，承载模型接入、网关前端与 PH01 登录集成
├── ph01-deploy/              # 三端生产部署脚本、Compose、预置配置和证书种子
├── ph01-experience-hub/      # 经验网络管理端（经验存储 + 主脑侧 CLI + 主控证书治理签名）
├── experience-dht/           # 独立 DHT / rendezvous / relay 协调端 MVP
├── legacy-p2p-authority/     # 历史拆分实现，生产治理能力已并入 ph01-experience-hub
└── master-server/            # 主脑端 / 服务端（独立 git，git@156.224.19.69:Angel/ph01_project_v2.git）
```

## 各子目录说明

### `flutter-migration-plan/`
Phase 0 起的设计与决策文档，含：
- `01-架构与可行性评估.md` / `02-多窗口实现方案.md` / `03-模块迁移清单.md` / `04-BUG甄别与重写策略.md` / `05-分阶段路线图与风险.md`
- `性能优化复盘-20260207.md` —— Windows / Android 高刷率与 GPU 选路修正经验
- `pubspec.yaml.template`

### `legacy-electron/`
原项目的完整 Electron 形态，已搬迁不再修改。可随时 `cd legacy-electron && npm install && npm start` 跑老版本作参考。

### `hanako-flutter/`
PH01 子体客户端实现：Flutter Desktop + Dart 后端共用 `lib/core/`，可编译为 GUI / CLI / Server 三种形态。底层 Agent 工具循环、工具注册/路由和提示词组织已迁入 OpenAI Codex 风格执行引擎。
- 进入开发：`cd hanako-flutter && flutter run -d windows`
- 详细说明：[`hanako-flutter/README.md`](./hanako-flutter/README.md)
- 变更日志：[`hanako-flutter/CHANGELOG.md`](./hanako-flutter/CHANGELOG.md)

### `openai-codex/`
OpenAI Codex 源码归档，用于本项目迁移 Agent 执行引擎逻辑。该目录保留上游 Apache-2.0 `LICENSE` 与 `NOTICE`；本项目只迁移 Agent 执行引擎领域逻辑，不引入 Codex CLI/TUI、登录、配置文件体系或云端状态。

### `ph01-backend/`
认证中心 / 授权中心，生产只部署 `auth-center`（源码入口是 `cmd/auth-gateway`）。它负责用户名、公钥、邮箱验证码、恢复二验、管理后台、签名验签，以及注册时同步创建 AI 网关账号。

目录内保留的 `cmd/legacy-ai-gateway` 是早期 Go 版 AI 网关原型，不是当前生产 AI 网关；正式 AI 网关见 `ph01-ai-gateway/`。
- 进入开发：`cd ph01-backend && go test ./...`
- 详细说明：[`ph01-backend/README.md`](./ph01-backend/README.md)

### `ph01-ai-gateway/`
正式 AI 网关，基于 New API 魔改。它自带后端和前端，承载模型接入、用户网关首页、PH01 认证中心登录集成、默认密钥/公开密钥规则、注册同步落库等能力。
- 生产镜像：`ph01-deploy/production/build-images.sh` 使用 `ph01-ai-gateway/Dockerfile`
- 生产配置：`data/production/config/ai-gateway.yaml`
- 集成说明：[`ph01-ai-gateway/docs/ph01-auth-integration.md`](./ph01-ai-gateway/docs/ph01-auth-integration.md)

### `ph01-deploy/`
三端官方服务生产部署目录。部署服务器上直接带走 `ph01-backend/`、`ph01-ai-gateway/`、`ph01-experience-hub/`、`ph01-deploy/`，持久化数据保留在同级 `data/production/`。DHT 不进入官方服务编排，使用 `experience-dht/` 或 Docker Hub 镜像独立部署。
- 部署说明：[`ph01-deploy/production/部署与密钥说明.md`](./ph01-deploy/production/部署与密钥说明.md)

### `ph01-experience-hub/`
独立的经验网络管理端，部署在大容量服务器上；主脑侧通过 `ph01-expctl` CLI 以 C/S 模式操作。生产版本同一进程还承载主控证书治理签名能力与公共 DHT 列表 / 注册 / 健康检查管理，但不承担独立 DHT 节点转发职责，Root 私钥仍离线冷保存。
- 进入开发：`cd ph01-experience-hub && go test ./...`
- 详细说明：[`ph01-experience-hub/README.md`](./ph01-experience-hub/README.md)
- 经验协议：[`docs/experience-package-spec.md`](./docs/experience-package-spec.md)

### `experience-dht/`
独立的 DHT / rendezvous / relay 协调端 MVP。它是单独产物，不内嵌进经验管理端进程，也不进入 `ph01-deploy/production` 官方服务编排；官方 DHT、客户 DHT、个人私有 DHT 都按独立镜像或独立部署包部署。
- 进入开发：`cd experience-dht && go test ./...`
- 详细说明：[`experience-dht/README.md`](./experience-dht/README.md)

### `legacy-p2p-authority/`
历史拆分出的 P2P 网络治理端。当前生产部署不再单独部署它，治理签名能力已合并进 `ph01-experience-hub`，并改为线上只持有主控私钥。
- 进入开发：`cd legacy-p2p-authority && go test ./...`
- 详细说明：[`legacy-p2p-authority/README.md`](./legacy-p2p-authority/README.md)

### `master-server/`
主脑端（服务端）独立仓库，由其自身 `.git` 管理，外层 PH01 工作区的 `.gitignore` 已忽略它。

```bash
cd master-server
git pull origin main   # 或对应分支
```

## 顶层 git

外层 git 负责当前 PH01 工作区；第三方源码归档和历史实现按各自许可保留来源说明。

## 许可与来源

Agent 执行引擎逻辑来源于 OpenAI Codex，遵循 Apache-2.0。上游源码、`LICENSE` 与 `NOTICE` 保留在 [`openai-codex/`](./openai-codex/)。

## SSH

`~/.ssh/id_ed25519`（key 名 `Angel-PC`）已注册到 Gitea，无需重新生成。`~/.ssh/config` 中 `github.com` 已配置；`156.224.19.69` 默认走该 key 连通正常。
