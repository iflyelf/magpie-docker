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
- 内置 MCP 运行时 **Node.js（`npm` / `npx`）** 与 **uv（`uv` / `uvx`）**，magpie 的
  MCP Library 可直接拉起 `npx` / `uvx` 类型的 stdio MCP server；Node 通过 **nvm** 安装最新 LTS，
  构建时优先国内镜像并自动回退官方源
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

## MCP 运行时（npx / uvx）

magpie 的 MCP Library 支持通过 `npx` / `uvx` 启动 stdio 类型 MCP server，镜像已内置：

| 命令 | 来源 | 说明 |
| --- | --- | --- |
| `nvm` | nvm 官方安装脚本 | 默认跟随最新版 nvm |
| `node` / `npm` / `npx` | nvm 安装的最新 Node LTS | 运行 npm 生态 MCP server |
| `uv` / `uvx` | uv 官方预编译包 | 运行 PyPI 生态 MCP server，Python 由 uv 自动下载到 `/config/data` |

Node.js 通过 nvm 安装到 `/usr/local/nvm`，并建立 `/usr/local/nvm/current` 指向当前 LTS，
因此非交互进程（magpie 拉起 MCP server）也能直接找到 `node` / `npx`：

```bash
# 校验运行时（无需联网）
docker exec magpie bash -lc 'nvm --version; node -v; npm -v; npx --version; uv --version; uvx --version'

# 查看 / 切换 Node 版本（交互式 shell 已自动加载 nvm）
docker exec -it magpie bash
nvm ls
nvm install 22 && nvm alias default 22

# 实测拉起一个 MCP server
docker exec magpie npx -y @modelcontextprotocol/server-everything --help
docker exec magpie uvx mcp-server-fetch --help
```

npm 镜像源已在构建时写入全局配置（`npm config get registry` 可查看），并同步通过
`NPM_CONFIG_REGISTRY` 生效：

```bash
docker exec magpie npm config get registry   # https://registry.npmmirror.com
```

依赖下载已做国内网络优化，**无需额外配置**：

- 构建期：nvm 安装脚本 / 仓库走 `gh-proxy.xiaonuo.live`，Node LTS 走清华 `nodejs-release` 镜像
  （含 `SHASUMS256.txt` 校验；失败自动回退 `nodejs.org`），uv 走 `ghproxy`
- 运行期：`npx` 默认使用 `registry.npmmirror.com`，`uvx` 默认使用清华 PyPI 镜像，
  uv 自动下载 Python 时默认走 `ghproxy`

海外网络或企业内网可在 `docker-compose.yml` 的 `environment` 中覆盖：

```yaml
environment:
  NPM_CONFIG_REGISTRY: https://registry.npmjs.org
  NVM_NODEJS_ORG_MIRROR: https://nodejs.org/dist
  UV_DEFAULT_INDEX: https://pypi.org/simple
  # 取消镜像加速时直接置空即可
  UV_PYTHON_INSTALL_MIRROR: ""
  UV_PYPY_INSTALL_MIRROR: ""
```

npm / npx 与 uv 的缓存都写入 `/config`，重启或换镜像后仍然复用。


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

Node.js（nvm）与 uv 的可执行文件安装在镜像的 `/usr/local` 下，不占用 `/config`；
npm / npx 缓存位于 `/config/home/.npm`，uv 缓存与自动下载的 Python 位于 `/config/cache`、`/config/data`。

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `TZ` | `Asia/Shanghai` | 时区 |
| `MAGPIE_ADDR` | `0.0.0.0:3425` | 网关监听地址（容器内必须 `0.0.0.0` 才能被宿主机访问） |
| `MAGPIE_WEB_KEY` | 随机 | 浏览器 UI 固定密钥（16 位以上），设置后重启仍有效 |
| `MAGPIE_PUBLIC_URL` | 空 | 其他机器访问网关使用的地址，如 `http://192.168.1.20:3425` |
| `MAGPIE_ALLOW_IPS` | 空 | 仅允许这些 IP / CIDR 访问网关与 UI，逗号分隔 |
| `MAGPIE_TLS_CERT` / `MAGPIE_TLS_KEY` | 空 | 网关与 UI 的 TLS 证书 / 私钥路径（挂载进容器） |
| `NPM_CONFIG_REGISTRY` | `https://registry.npmmirror.com` | `npx` / `npm` 默认源，海外可覆盖为官方源 |
| `NVM_DIR` | `/usr/local/nvm` | nvm 与 Node.js 安装目录（镜像内） |
| `NVM_NODEJS_ORG_MIRROR` | `https://mirrors.tuna.tsinghua.edu.cn/nodejs-release` | `nvm install` 下载 Node.js 的镜像（含校验文件），失败回退官方源 |
| `UV_DEFAULT_INDEX` | `https://pypi.tuna.tsinghua.edu.cn/simple` | `uvx` 默认 PyPI 源，海外可覆盖为官方源 |
| `UV_PYTHON_INSTALL_MIRROR` | `ghproxy` 加速 | uv 自动下载 Python 时的镜像，置空使用官方源 |
| `UV_PYPY_INSTALL_MIRROR` | `ghproxy` 加速 | uv 自动下载 PyPy 时的镜像，置空使用官方源 |
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
| `NVM_INSTALL_URL` | `gh-proxy` 加速的 nvm `install.sh` | nvm 安装脚本地址，失败回退官方 raw |
| `NVM_GIT_URL` | `gh-proxy` 加速的 nvm 仓库 | nvm 源码地址，失败回退 `github.com/nvm-sh/nvm.git` |
| `NODE_MIRROR` | `https://mirrors.tuna.tsinghua.edu.cn/nodejs-release` | `nvm install` 下载 Node 的镜像（含 `SHASUMS256.txt`），失败回退官方源 |
| `NPM_REGISTRY` | `https://registry.npmmirror.com` | 写入 npm 全局配置并作为 `NPM_CONFIG_REGISTRY` |
| `UV_VERSION` | `0.13.7` | 内置 uv 版本（含 `uvx`） |
| `UV_MIRROR` | `https://ghproxy.net/https://github.com/astral-sh/uv/releases/download` | uv 下载镜像，失败自动回退 `github.com` |

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
| MCP 运行时 | 未内置 | 内置 Node.js（`npx`）+ uv（`uvx`），国内镜像加速 |
| 特权模式 | 未适配 | 适配 `pid: host` / `ipc: host` / `privileged: true` |
| 状态目录 | `/config` | `/config`（兼容） |
| 推送仓库 | GHCR | Docker Hub + 华为云 SWR |

## 许可

MIT，详见 [LICENSE](./LICENSE)。magpie 版权归其作者所有。
