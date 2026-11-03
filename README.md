# magpie-docker

[magpie](https://github.com/yetone/magpie) 的 Docker 镜像。magpie 是一个本地 AI Agent 模型网关：
把 Claude Code、Codex、Gemini CLI、OpenCode、Cursor 等 Agent 的模型统一到一处，支持多供应商、
多账号轮换、路由分组、订阅登录与隐私脱敏。

- 上游项目：<https://github.com/yetone/magpie>
- 本仓库：<https://github.com/iflyelf/magpie-docker>
- 镜像地址：
  - Docker Hub：`iflyelf/magpie`
  - 华为云 SWR（国内推荐）：`swr.cn-east-3.myhuaweicloud.com/iflyelf/magpie`
- 支持架构：`linux/amd64`、`linux/arm64`

## 特性

- **分阶段构建**
  - 构建阶段：`iflyelf/ubuntu:latest`（预装 Go / Node / Python / 完整工具链），无需重复安装庞大依赖，构建更快更稳
  - 运行阶段：`iflyelf/ubuntu:lite`，仅拷贝编译产物，体积更小
  - 通过 `CGO_ENABLED=0` 交叉编译，多架构构建不依赖 QEMU 跑 Go 编译器
- **默认 root 启动**，可直接配合以下 Docker 特权配置使用：

  ```yaml
  # 宿主机共享进程命名空间
  pid: host
  # 使用系统的 IPC 命名空间
  ipc: host
  # 允许容器中运行一些特权命令
  privileged: true
  ```

- 运行阶段补齐 magpie 运行所需依赖（bash / curl / ca-certificates / git / 解压工具 /
  libstdc++ / libgcc / procps / tini / util-linux），订阅登录与厂商 CLI 安装脚本可直接运行
- 所有状态持久化到 `/config`，重启、换新镜像不丢 providers、密钥、订阅登录态与插件
- 内置 `HEALTHCHECK`（`magpie healthcheck`），`docker ps` 可直接看到健康状态
- 版本自动跟随上游最新 Tag（每天定时检查），也可手动指定版本触发构建

## 快速开始

### 1. Docker Compose（推荐）

```bash
mkdir -p magpie/config
cd magpie

# 生成浏览器 UI 固定密钥
echo "MAGPIE_WEB_KEY=$(openssl rand -hex 16)"

docker compose up -d
docker logs -f magpie
```

仓库根目录已提供 [`docker-compose.yml`](./docker-compose.yml)，其中包含 `pid: host`、
`ipc: host`、`privileged: true` 与 `user: "0:0"`。

打开浏览器 UI：

```text
http://<宿主机IP>:3430/?k=<MAGPIE_WEB_KEY>
```

> 不设置 `MAGPIE_WEB_KEY` 时，每次启动都会生成随机密钥，请从 `docker logs magpie` 中查看带 `?k=` 的链接。

### 2. docker run

```bash
docker run -d --name magpie --restart unless-stopped \
  --user 0:0 \
  --pid host --ipc host --privileged \
  -p 3425:3425 -p 3430:3430 \
  -e TZ=Asia/Shanghai \
  -e MAGPIE_ADDR=0.0.0.0:3425 \
  -e MAGPIE_WEB_KEY="$(openssl rand -hex 16)" \
  -v "$PWD/config:/config" \
  iflyelf/magpie:latest \
  web --addr 0.0.0.0:3430 --no-open
```

只用网关、不需要浏览器 UI 时，把最后的命令改成 `serve`（或直接省略，镜像默认就是 `serve`）：

```bash
docker run -d --name magpie --restart unless-stopped \
  --user 0:0 --pid host --ipc host --privileged \
  -p 3425:3425 -v "$PWD/config:/config" \
  iflyelf/magpie:latest
```

### 3. 接入 Agent

在浏览器 UI 或容器内 CLI 添加 provider、登录订阅：

```bash
# 进入容器（默认 root，shell 为 zsh）
docker exec -it magpie zsh

magpie provider add deepseek sk-xxxx
magpie accounts add codex
magpie gateway-key add "Laptop"     # 其他机器访问网关时使用的密钥
```

其他机器上的 Agent 指向网关：

```bash
export OPENAI_BASE_URL=http://<宿主机IP>:3425/v1
export OPENAI_API_KEY=sk-magpie-key-...

export ANTHROPIC_BASE_URL=http://<宿主机IP>:3425
export ANTHROPIC_API_KEY=sk-magpie-key-...

export GOOGLE_GEMINI_BASE_URL=http://<宿主机IP>:3425
export GEMINI_API_KEY=sk-magpie-key-...
```

## 端口

| 端口 | 用途 |
| --- | --- |
| `3425` | 网关：OpenAI / Anthropic / Gemini 兼容接口，Agent 调用 |
| `3430` | 浏览器 UI（`magpie web`） |

## 数据卷

| 路径 | 内容 |
| --- | --- |
| `/config/magpie` | magpie 自身配置：`settings.json`、providers、网关密钥、路由分组 |
| `/config/home` | 容器内 `HOME`：订阅登录态（`~/.codex`、`~/.claude` 等）与厂商 CLI |
| `/config/cache` | 模型目录、插件运行时 Bun、`magpie claude-code install` 下载的 Claude Code |
| `/config/data`、`/config/state` | magpie 其余数据 |

挂载宿主机目录时容器以 root 写入，无需再 `chown 65532`。

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `TZ` | `Asia/Shanghai` | 时区 |
| `MAGPIE_ADDR` | `0.0.0.0:3425` | 网关监听地址（容器内必须 `0.0.0.0` 才能被宿主机访问） |
| `MAGPIE_WEB_KEY` | 随机 | 浏览器 UI 固定密钥（16 位以上），设置后重启仍有效 |
| `MAGPIE_PUBLIC_URL` | 空 | 其他机器访问网关使用的地址，如 `http://192.168.1.20:3425` |
| `MAGPIE_ALLOW_IPS` | 空 | 仅允许这些 IP / CIDR 访问网关与 UI，逗号分隔 |
| `MAGPIE_TLS_CERT` / `MAGPIE_TLS_KEY` | 空 | 网关与 UI 的 TLS 证书 / 私钥路径（挂载进容器） |
| `HOME` / `XDG_*` | `/config/...` | 镜像已设置，将全部状态收敛到 `/config`，不建议修改 |

## 特权模式说明

镜像本身不依赖特权即可运行；`pid: host`、`ipc: host`、`privileged: true`、`user: "0:0"`
用于让容器内的 magpie 具备与宿主机同等的进程可见性与操作能力（例如直接管理宿主机上的
Agent 进程、改写宿主机 Agent 配置、运行需要特权的诊断命令）。

> ⚠️ **安全提示**：`privileged: true` + `pid: host` + root 等同于把宿主机的大量控制权交给容器。
> 请只在自己信任的宿主机上使用，不要把 `3430`/`3425` 直接暴露到公网；跨网络访问请使用
> VPN、SSH 隧道或带 TLS 的反向代理，并配置 `MAGPIE_ALLOW_IPS` 与网关密钥。

可选地把宿主机上已有 Agent 的配置挂载进来，让 magpie 直接接管：

```yaml
volumes:
  - ./config:/config
  - /root/.claude:/config/home/.claude
  - /root/.codex:/config/home/.codex
  - /root/.config/opencode:/config/home/.config/opencode
```

## 健康检查与终端

```bash
# 健康状态
docker inspect --format '{{.State.Health.Status}}' magpie

# 进入容器
docker exec -it magpie zsh

# 查看与验证
magpie healthcheck
magpie providers
magpie models
magpie quota
```

## 本地构建

```bash
# 默认跟随上游 main 分支
docker build -t magpie:local .

# 构建指定上游版本（branch / tag / commit 均可）
docker build \
  --build-arg MAGPIE_REF=v0.1.2816 \
  --build-arg VERSION=v0.1.2816 \
  -t magpie:local .

# 冒烟测试
./scripts/smoke-test.sh magpie:local
```

构建参数：

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `MAGPIE_REPO` | `https://github.com/yetone/magpie.git` | 上游仓库地址（可换镜像源） |
| `MAGPIE_REF` | `main` | 上游 branch / tag / commit |
| `VERSION` | `dev` | 写入二进制的版本号（`-X main.version`） |
| `GOPROXY` | `https://goproxy.cn,direct` | Go 模块代理 |

## 自动构建（GitHub Actions）

工作流：[`.github/workflows/docker-publish.yml`](./.github/workflows/docker-publish.yml)

- **版本自动更新**：构建前通过 GitHub API 读取上游最新 Release / Tag，自动注入
  `MAGPIE_REF` 与 `VERSION`；每天中国时间 05:00 定时构建，上游发版后镜像自动跟进
- **多架构**：`linux/amd64`、`linux/arm64`
- **推送目标**：Docker Hub 与华为云 SWR，同时打 `latest` 与版本号 tag
- **冒烟测试**：推送后拉取 amd64 镜像验证网关、CLI、`/config` 卷与 `/v1` 接口
- **SWR 兼容**：关闭 provenance / sbom，使用 Docker 媒体类型，避免 SWR 解析失败
- **同一分支并发控制**：`concurrency` + `cancel-in-progress`，避免多架构构建堆积
- **触发方式**：推送 `Dockerfile` / 工作流、手动 `workflow_dispatch`、每天定时、Star 仓库

手动触发并指定版本：

```bash
curl -X POST \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/iflyelf/magpie-docker/actions/workflows/docker-publish.yml/dispatches" \
  -d '{"ref":"main","inputs":{"version":"v0.1.2816"}}'
```

### 所需 Secrets

| Secret | 说明 |
| --- | --- |
| `DOCKER_USERNAME` / `DOCKER_PASSWORD` | Docker Hub 凭据 |
| `SWR_USERNAME` / `SWR_PASSWORD` | 华为云 SWR 登录凭据（`区域@AK` / 登录密钥） |
| `SWR_AK` / `SWR_SK` | 华为云账号 AK/SK，用于将 SWR 仓库设为公开（可选） |

## 与上游镜像的差异

| 项目 | 上游 `ghcr.io/yetone/magpie` | 本镜像 |
| --- | --- | --- |
| 构建基础 | `golang:1.26-alpine` | `iflyelf/ubuntu:latest` |
| 运行基础 | `debian:12-slim` | `iflyelf/ubuntu:lite` |
| 用户 | nonroot（uid 65532） | **root**（可用 `user:` 覆盖） |
| 特权模式 | 未适配 | 适配 `pid: host` / `ipc: host` / `privileged: true` |
| 状态目录 | `/config` | `/config`（兼容） |
| 推送仓库 | GHCR | Docker Hub + 华为云 SWR |

## 许可

MIT，详见 [LICENSE](./LICENSE)。magpie 版权归其作者所有。
