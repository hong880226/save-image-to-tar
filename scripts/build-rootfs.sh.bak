#!/usr/bin/env bash
set -euo pipefail

ROOTFS_DIR="/tmp/openclaw-rootfs"
DIST_DIR="${GITHUB_WORKSPACE:-$(pwd)}/dist"
mkdir -p "$DIST_DIR"
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"

# 1) 用 debootstrap 构建最小 Debian 12 rootfs
# GitHub runner 自带 debootstrap 可能没有，直接 apt 装
apt-get update
apt-get install -y debootstrap

debootstrap --variant=minbase bookworm "$ROOTFS_DIR" http://deb.debian.org/debian

# 2) 基础配置 + 常用工具（尽量克制以减小体积）
chroot "$ROOTFS_DIR" bash -lc '
set -e
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl tzdata bash tini \
  iproute2 net-tools procps \
  openssl \
  dumb-init

ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone

# 创建用户（可选：你也可以只用 root）
useradd -m -s /bin/bash hong || true
'

# 3) 安装 OpenClaw（这里按“从 Release 下载二进制”写）
# 你需要把下面两个 URL 的规则改成 OpenClaw 实际发布地址/文件名
# - OPENCLAW_VERSION 为空：取 latest
# - 否则：取指定 tag
OPENCLAW_VERSION="${OPENCLAW_VERSION:-}"

get_latest_tag() {
  curl -fsSL "https://api.github.com/repos/openclawai/openclaw/releases/latest" | jq -r .tag_name
}

TAG="$OPENCLAW_VERSION"
if [[ -z "$TAG" ]]; then
  TAG="$(get_latest_tag)"
fi

# 根据实际 release 命名调整：
# 假设：
#   openclaw-linux-amd64.tar.gz 里包含 openclaw 可执行文件
#   openclaw-control-ui-dist.tar.gz 里是前端静态文件（或者你用单独镜像/服务）
OPENCLAW_BIN_URL="https://github.com/openclawai/openclaw/releases/download/${TAG}/openclaw-linux-amd64.tar.gz"
CONTROL_UI_URL="https://github.com/openclawai/openclaw-control-ui/releases/download/${TAG}/openclaw-control-ui-dist.tar.gz"

echo "Using OpenClaw tag: ${TAG}"
echo "Download: ${OPENCLAW_BIN_URL}"
echo "Download: ${CONTROL_UI_URL}"

mkdir -p "$ROOTFS_DIR/opt/openclaw/bin" "$ROOTFS_DIR/opt/openclaw/control-ui"

# 下载并解压到 rootfs
curl -fL "$OPENCLAW_BIN_URL" -o /tmp/openclaw-bin.tgz
tar -xzf /tmp/openclaw-bin.tgz -C "$ROOTFS_DIR/opt/openclaw/bin"

# control-ui（若没有单独发布包，你可以先注释掉这段，后续我按你实际改）
if curl -fsSLI "$CONTROL_UI_URL" >/dev/null 2>&1; then
  curl -fL "$CONTROL_UI_URL" -o /tmp/openclaw-ui.tgz
  tar -xzf /tmp/openclaw-ui.tgz -C "$ROOTFS_DIR/opt/openclaw/control-ui"
fi

# 放到 PATH
chroot "$ROOTFS_DIR" bash -lc '
set -e
ln -sf /opt/openclaw/bin/openclaw /usr/local/bin/openclaw || true
'

# 4) 默认目录（你要持久化的配置/日志）
mkdir -p "$ROOTFS_DIR/var/lib/openclaw/config" "$ROOTFS_DIR/var/log/openclaw"

# 5) 启动脚本（WSL 下不强依赖 systemd）
cat > "$ROOTFS_DIR/usr/local/bin/start-openclaw.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export TZ=Asia/Shanghai
export OPENCLAW_CONFIG_DIR=${OPENCLAW_CONFIG_DIR:-/var/lib/openclaw/config}
export OPENCLAW_LOG_DIR=${OPENCLAW_LOG_DIR:-/var/log/openclaw}

mkdir -p "$OPENCLAW_CONFIG_DIR" "$OPENCLAW_LOG_DIR"

# 网关端口（按你需要改）
GATEWAY_PORT="${GATEWAY_PORT:-18791}"
UI_PORT="${UI_PORT:-3000}"

# 1) 启动 gateway
# 假设 openclaw 会读取默认配置目录；若它只认 ~/.openclaw，你可以把配置软链到 /root/.openclaw 或 /home/hong/.openclaw
export HOME=/root
mkdir -p /root/.openclaw
# 可选：把 /var/lib/openclaw/config 映射为 ~/.openclaw
mountpoint -q /root/.openclaw 2>/dev/null || true
if [ -d "$OPENCLAW_CONFIG_DIR" ]; then
  rm -rf /root/.openclaw
  ln -s "$OPENCLAW_CONFIG_DIR" /root/.openclaw
fi

nohup openclaw gateway start --port "$GATEWAY_PORT" \
  >>"$OPENCLAW_LOG_DIR/gateway.log" 2>&1 &

# 2) 启动 control-ui（按你的 UI 实际启动方式调整）
# 如果 control-ui 是纯静态文件：用一个极小 http server（这里用 busybox httpd 方案需要 busybox）
# 如果你 control-ui 需要 node server，你得安装 node，这会变大。
if command -v busybox >/dev/null 2>&1 && [ -d /opt/openclaw/control-ui ]; then
  nohup busybox httpd -f -p "$UI_PORT" -h /opt/openclaw/control-ui \
    >>"$OPENCLAW_LOG_DIR/control-ui.log" 2>&1 &
fi

echo "OpenClaw gateway: http://localhost:${GATEWAY_PORT}"
echo "Control UI:       http://localhost:${UI_PORT}"
echo "Logs:             ${OPENCLAW_LOG_DIR}"
EOF
chmod +x "$ROOTFS_DIR/usr/local/bin/start-openclaw.sh"

# 6) 瘦身：清理 apt cache、文档
chroot "$ROOTFS_DIR" bash -lc '
set -e
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* /var/cache/*
'

# 7) 打包 rootfs（tar + zstd）
OUT="$DIST_DIR/openclaw-debian12-wsl-rootfs-${TAG}-amd64.tar"
tar -C "$ROOTFS_DIR" -cf "$OUT" .
zstd -19 -T0 --rm "$OUT"
echo "Done: ${OUT}.zst"
