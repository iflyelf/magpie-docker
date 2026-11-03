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

# 拷贝编译产物与预创建的配置目录
COPY --from=builder /out/magpie /magpie
COPY --from=builder /out/config /config

RUN set -eux; \
    chmod 0755 /magpie; \
    ln -sf /magpie /usr/local/bin/magpie

# 环境变量:
#   HOME / XDG_*  所有状态写入 /config, 重启或换新镜像不丢失
#   MAGPIE_ADDR   网关监听地址, 容器内必须 0.0.0.0 才能被宿主机访问
#   PATH          厂商 CLI 默认安装目录 (root 的 HOME 在 /config/home)
ENV HOME=/config/home \
    XDG_CONFIG_HOME=/config \
    XDG_CACHE_HOME=/config/cache \
    XDG_DATA_HOME=/config/data \
    XDG_STATE_HOME=/config/state \
    MAGPIE_ADDR=0.0.0.0:3425 \
    PATH=/config/home/.local/bin:/config/home/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

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
