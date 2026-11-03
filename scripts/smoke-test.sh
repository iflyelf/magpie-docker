#!/usr/bin/env bash
# 本地冒烟测试: 构建 linux/amd64 镜像并验证网关、CLI 与 /config 卷
set -euo pipefail

IMAGE="${1:-magpie-smoke:local}"
NAME="magpie-smoke-$$"
VOLUME="magpie-smoke-$$"
KEY="sk-ci-gateway-key"

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker volume rm "$VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> 构建镜像 $IMAGE"
docker build -t "$IMAGE" .

echo "==> 写入 provider 与网关密钥 (同时验证 /config 卷可写)"
OUT=$(docker run --rm -v "$VOLUME:/config" "$IMAGE" \
        provider add ci-smoke key=sk-ci url=https://example.com)
echo "$OUT"
echo "$OUT" | grep -q 'added ci-smoke'
docker run --rm -v "$VOLUME:/config" "$IMAGE" gateway-key add ci-smoke --key "$KEY" >/dev/null

echo "==> 启动容器"
docker run -d --name "$NAME" -v "$VOLUME:/config" -p 13425:3425 "$IMAGE" >/dev/null

echo "==> 等待网关就绪 (新版 magpie 对容器外请求强制要求网关密钥)"
READY=0
for _ in $(seq 1 40); do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${KEY}" "http://127.0.0.1:13425/v1/models" || true)
  if [ "$CODE" = 200 ]; then READY=1; break; fi
  sleep 1
done
[ "$READY" = 1 ] || { echo "ERROR: 网关未在 40 秒内就绪"; docker logs "$NAME"; exit 1; }

echo "==> 校验 CLI 与配置目录"
docker exec "$NAME" /bin/bash -c 'magpie healthcheck && ls -la /config'
docker exec "$NAME" /bin/sh -c 'echo sh works'

echo "==> 校验 /v1/chat/completions 返回 JSON 错误"
CODE=$(curl -s -o /tmp/magpie-smoke-body.json -w '%{http_code}' \
  -H "Authorization: Bearer ${KEY}" -H 'Content-Type: application/json' \
  -d '{"model":"ci-unknown-model","messages":[{"role":"user","content":"hi"}]}' \
  "http://127.0.0.1:13425/v1/chat/completions")
echo "HTTP $CODE"
cat /tmp/magpie-smoke-body.json; echo
[ "$CODE" -ge 400 ] && [ "$CODE" -lt 500 ]
jq -e '.error.type' /tmp/magpie-smoke-body.json >/dev/null

echo "✅ 冒烟测试通过"
