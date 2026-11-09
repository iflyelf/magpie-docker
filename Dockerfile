# syntax=docker/dockerfile:1
#=================================================
# magpie 镜像
# 上游: https://github.com/yetone/magpie
# 镜像: https://github.com/iflyelf/magpie-docker
# Lisence: MIT
#=================================================
#
# 分阶段构建:
#   builder = iflyelf/ubuntu:latest  预装 Go / Node / Python / 完整工具链,
#                                     无需重复安装庞大的依赖列表, 构建更快更稳
#   runtime = iflyelf/ubuntu:lite    仅拷贝编译产物, 体积更小
#
# 运行阶段额外安装 magpie 运行所需依赖并设置环境变量,
# 默认以 root 启动, 可配合 docker 的 --privileged / --pid=host / --ipc=host 使用。

#############################
#      构建阶段 builder      #
#############################
# 使用 BUILDPLATFORM 在本机构建, 通过 CGO_ENABLED=0 交叉编译目标架构,
# 避免多架构 (QEMU) 构建时让 Go 编译器在模拟环境中运行, 显著提速。
FROM --platform=$BUILDPLATFORM iflyelf/ubuntu:latest AS builder

LABEL org.opencontainers.image.authors="iflyelf" \
      org.opencontainers.image.vendor="iflyelf" \
      org.opencontainers.image.title="magpie-docker" \
      org.opencontainers.image.description="magpie - 统一的 AI Agent 模型网关 (builder)"

ARG TZ=Asia/Shanghai
ENV TZ=${TZ}

# magpie 源码与版本: GitHub Actions 会解析上游最新 Tag 后通过 --build-arg 注入
# MAGPIE_REF 支持 branch / tag / commit
ARG MAGPIE_REPO=https://github.com/yetone/magpie.git
ARG MAGPIE_REF=main
ARG VERSION=dev

# Go 模块代理 (国内加速, 海外构建可覆盖为 https://proxy.golang.org,direct)
ARG GOPROXY=https://goproxy.cn,direct
ENV GOPROXY=${GOPROXY}

WORKDIR /src

# 拉取指定版本源码 (fetch 指定 ref 后可兼容 branch / tag / commit)
RUN set -eux; \
    git init -q .; \
    git remote add origin "${MAGPIE_REPO}"; \
    git fetch --depth 1 origin "${MAGPIE_REF}"; \
    git checkout -q --detach FETCH_HEAD; \
    echo "magpie source: $(git rev-parse HEAD)"

# 编译终端版 (nogui): 不依赖 GTK / WebKit, 可静态交叉编译
ARG TARGETOS=linux
ARG TARGETARCH

RUN set -eux; \
    export GOOS="${TARGETOS:-linux}"; \
    export GOARCH="${TARGETARCH:-$(go env GOARCH)}"; \
    export CGO_ENABLED=0; \
    go build -tags nogui -trimpath \
        -ldflags "-s -w -X main.version=${VERSION}" \
        -o /out/magpie .; \
    ls -lh /out/magpie

# 预先创建运行阶段的目录结构并按 root 拥有
RUN mkdir -p /out/config/home /out/config/cache /out/config/data \
             /out/config/state /out/config/magpie


#############################
#      运行阶段 runtime      #
#############################
FROM iflyelf/ubuntu:lite

LABEL org.opencontainers.image.authors="iflyelf" \
      org.opencontainers.image.vendor="iflyelf" \
      org.opencontainers.image.title="magpie-docker" \
      org.opencontainers.image.description="magpie - 统一的 AI Agent 模型网关 (root / privileged / host pid & ipc)" \
      org.opencontainers.image.source="https://github.com/iflyelf/magpie-docker" \
      org.opencontainers.image.url="https://github.com/iflyelf/magpie-docker"

ARG TZ=Asia/Shanghai
ENV TZ=${TZ}

# 运行阶段按需补充依赖 (lite 镜像已自带 bash/curl/git/tar/unzip/procps/tini 等,
# 这里显式声明, 防止 lite 后续精简导致运行期缺包):
#   bash / curl / ca-certificates  订阅登录与厂商 CLI 的 `curl … | bash` 一键安装
#   git / openssh-client           插件与部分 agent 工具链
#   libstdc++6 / libgcc-s1         插件运行时 Bun 所需的 glibc 组件
#   xz-utils / gzip / unzip / zip  下载包解压
#   procps / tini                  进程查看 (配合 pid: host) 与 PID 1 信号回收
#   util-linux                     提供 nsenter / mount 等特权环境常用命令
ARG PKG_DEPS="\
    bash \
    ca-certificates \
    curl \
    git \
    openssh-client \
    libstdc++6 \
    libgcc-s1 \
    xz-utils \
    gzip \
    unzip \
    zip \
    tar \
    procps \
    tini \
    util-linux"
ENV PKG_DEPS=${PKG_DEPS}

RUN set -eux; \
    apt-get update -qq; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends ${PKG_DEPS}; \
    # 逐个校验依赖是否真正安装成功, 缺失则构建失败
    for pkg in ${PKG_DEPS}; do \
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then \
            echo "ERROR: 依赖包未成功安装: $pkg" >&2; exit 1; \
        fi; \
    done; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

#=================================================
# MCP 运行时: Node.js (nvm + npm / npx) + uv (uv / uvx)
#=================================================
# magpie 的 MCP Library 会用 `npx` / `uvx` 拉起 stdio 类型的 MCP server,
# iflyelf/ubuntu:lite 不自带这两个运行时, 这里按目标架构安装:
#   - Node.js: 通过 nvm 安装最新 LTS (nvm 也安装最新版)
#   - uv: uv 官方预编译包 (自带 uvx)
# 所有下载优先国内镜像, 失败自动回退官方源; 版本/镜像均可通过 --build-arg 覆盖。
ARG NVM_INSTALL_URL=https://gh-proxy.xiaonuo.live/https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh
ARG NVM_GIT_URL=https://gh-proxy.xiaonuo.live/https://github.com/nvm-sh/nvm.git
ARG NODE_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/nodejs-release
ARG NPM_REGISTRY=https://registry.npmmirror.com
ARG UV_VERSION=0.13.7
ARG UV_MIRROR=https://ghproxy.net/https://github.com/astral-sh/uv/releases/download

RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) uv_arch=x86_64  ;; \
        arm64) uv_arch=aarch64 ;; \
        *) echo "ERROR: 不支持的架构: $arch" >&2; exit 1 ;; \
    esac; \
    fetch() { \
        dest="$1"; shift; \
        for url in "$@"; do \
            echo "==> 下载: $url"; \
            if curl -fSL --connect-timeout 15 --retry 2 --retry-delay 3 -o "$dest" "$url"; then \
                return 0; \
            fi; \
            echo "WARN: 下载失败, 尝试下一个源" >&2; \
        done; \
        echo "ERROR: 所有下载源均失败" >&2; \
        return 1; \
    }; \
    export NVM_DIR=/usr/local/nvm; \
    export PROFILE=/dev/null; \
    export METHOD=git; \
    export NVM_NODEJS_ORG_MIRROR="${NODE_MIRROR}"; \
    mkdir -p "$NVM_DIR"; \
    fetch /tmp/nvm-install.sh \
        "${NVM_INSTALL_URL}" \
        "https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh"; \
    if ! NVM_SOURCE="${NVM_GIT_URL}" bash /tmp/nvm-install.sh; then \
        echo "WARN: 通过镜像安装 nvm 失败, 回退官方源" >&2; \
        NVM_SOURCE="https://github.com/nvm-sh/nvm.git" bash /tmp/nvm-install.sh; \
    fi; \
    rm -f /tmp/nvm-install.sh; \
    [ -s "${NVM_DIR}/nvm.sh" ] || { echo "ERROR: nvm 安装失败" >&2; exit 1; }; \
    if ! bash -c '. "$NVM_DIR/nvm.sh" && nvm install --lts'; then \
        echo "WARN: 通过 ${NODE_MIRROR} 安装 Node 失败, 回退官方源" >&2; \
        rm -rf "${NVM_DIR}/versions/node" "${NVM_DIR}/.cache"; \
        NVM_NODEJS_ORG_MIRROR=https://nodejs.org/dist bash -c '. "$NVM_DIR/nvm.sh" && nvm install --lts'; \
    fi; \
    bash -c '. "$NVM_DIR/nvm.sh" && nvm alias default "lts/*" && nvm use default'; \
    NODE_VER="$(bash -c '. "$NVM_DIR/nvm.sh" --no-use; nvm version default')"; \
    NODE_BIN="${NVM_DIR}/versions/node/${NODE_VER}/bin"; \
    ln -sfn "$(dirname "$NODE_BIN")" "${NVM_DIR}/current"; \
    "${NODE_BIN}/npm" config set registry "${NPM_REGISTRY}" --location=global; \
    printf '%s\n' \
        'export NVM_DIR="/usr/local/nvm"' \
        '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"' \
        > /etc/profile.d/nvm.sh; \
    chmod 0644 /etc/profile.d/nvm.sh; \
    if [ -f /etc/bash.bashrc ] && ! grep -q 'nvm.sh' /etc/bash.bashrc; then \
        printf '%s\n' \
            'export NVM_DIR="/usr/local/nvm"' \
            '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"' \
            >> /etc/bash.bashrc; \
    fi; \
    fetch /tmp/uv.tar.gz \
        "${UV_MIRROR}/${UV_VERSION}/uv-${uv_arch}-unknown-linux-gnu.tar.gz" \
        "https://gh-proxy.com/https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${uv_arch}-unknown-linux-gnu.tar.gz" \
        "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${uv_arch}-unknown-linux-gnu.tar.gz"; \
    tmp="$(mktemp -d)"; \
    tar -xzf /tmp/uv.tar.gz -C "$tmp"; \
    set -- "$tmp"/uv-*; \
    install -m 0755 "$1/uv" "$1/uvx" /usr/local/bin/; \
    rm -rf "$tmp" /tmp/uv.tar.gz; \
    "${NODE_BIN}/node" --version; \
    "${NODE_BIN}/npm" --version; \
    "${NODE_BIN}/npx" --version; \
    "${NODE_BIN}/npm" config get registry; \
    uv --version; \
    uvx --version

# 拷贝编译产物与预创建的配置目录
COPY --from=builder /out/magpie /magpie
COPY --from=builder /out/config /config

RUN set -eux; \
    chmod 0755 /magpie; \
    ln -sf /magpie /usr/local/bin/magpie

# 环境变量:
#   HOME / XDG_*  所有状态写入 /config, 重启或换新镜像不丢失
#   MAGPIE_ADDR   网关监听地址, 容器内必须 0.0.0.0 才能被宿主机访问
#   NVM_DIR       nvm 与 Node.js 安装在镜像内 (不在 /config, 避免被数据卷覆盖)
#   PATH          默认 Node LTS 的 bin 目录 + 厂商 CLI 默认安装目录
#   NPM_CONFIG_REGISTRY / NVM_NODEJS_ORG_MIRROR / UV_*
#                 运行期 npx / uvx 拉包与 nvm 安装 Node 也默认走国内镜像,
#                 避免首次启动 MCP server 时卡在境外源; 海外使用可覆盖为官方值
ENV HOME=/config/home \
    XDG_CONFIG_HOME=/config \
    XDG_CACHE_HOME=/config/cache \
    XDG_DATA_HOME=/config/data \
    XDG_STATE_HOME=/config/state \
    MAGPIE_ADDR=0.0.0.0:3425 \
    NVM_DIR=/usr/local/nvm \
    NPM_CONFIG_REGISTRY=${NPM_REGISTRY} \
    NVM_NODEJS_ORG_MIRROR=${NODE_MIRROR} \
    UV_DEFAULT_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple \
    UV_PYTHON_INSTALL_MIRROR=https://ghproxy.net/https://github.com/astral-sh/python-build-standalone/releases/download \
    UV_PYPY_INSTALL_MIRROR=https://ghproxy.net/https://github.com/astral-sh/pypy/releases/download \
    PATH=/usr/local/nvm/current/bin:/config/home/.local/bin:/config/home/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 默认以 root 运行: 可配合 pid: host / ipc: host / privileged: true
# 直接操作宿主机上的进程与 agent 配置
USER root

VOLUME ["/config"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ["/magpie", "healthcheck"]

# 3425 网关 / 3430 浏览器 UI
EXPOSE 3425 3430

# tini 作为 PID 1 回收僵尸进程; 传参行为与上游镜像一致
ENTRYPOINT ["/usr/bin/tini", "--", "/magpie"]
CMD ["serve"]
