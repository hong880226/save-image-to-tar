#!/usr/bin/env bash
set -euo pipefail

# 你需要根据项目实际产物调整这几个变量
# 常见情况：
# - CLI: dist/cli.js 或 dist/index.js
# - Server: dist/server.js
# - 需要配置：复制默认 config 模板
OPENCLAW_BUILD_DIR="${OPENCLAW_BUILD_DIR:-$(pwd)}"  # 在 workflow 中当前目录通常是 openclaw/
ROOTFS_DIR="/tmp/openclaw-rootfs"
DIST_DIR="${OPENCLAW_BUILD_DIR}/dist"

mkdir -p "$DIST_DIR"
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"

# 1) 构建最小 Debian
debootstrap --variant=minbase bookworm "$ROOTFS_DIR" http://deb.debian.org/debian

# 2) 安装运行时依赖（如果 OpenClaw 运行必须要 Node，这里必须装 node）
# 关键：不要把 build-time 的 node_modules 带进 rootfs；rootfs 里只装 node runtime + 你的 dist
chroot "$ROOTFS_DIR" bash -lc '
set -e
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl tzdata bash \
  tini dumb-init \
  nodejs \
  iproute2 procps
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* || true
'

# 3) 拷贝运行产物
# 你需要确认：npm run build 输出在哪（比如 openclaw/dist）
# 这里先假设仓库根目录下有 dist/ 目录
if [[ ! -d "${OPENCLAW_BUILD_DIR}/dist" ]]; then
  echo "ERROR: dist/ not found. Please adjust build output path."
  exit 1
fi

mkdir -p "$ROOTFS_DIR/opt/openclaw/app"
rsync -a --delete "${OPENCLAW_BUILD_DIR}/dist/" "$ROOTFS_DIR/opt/openclaw/app/"

# 4) 配置/日志目录
mkdir -p "$ROOTFS_DIR/var/lib/openclaw/config" "$ROOTFS_DIR/var/log/openclaw"
mkdir -p "$ROOTFS_DIR/usr/local/bin"

# 5) 启动脚本（你需要把 node 启动入口改成实际文件）
cat > "$ROOTFS_DIR/usr/local/bin/start-openclaw.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export TZ=Asia/Shanghai
export OPENCLAW_HOME=${OPENCLAW_HOME:-/var/lib/openclaw}
export OPENCLAW_LOG_DIR=${OPENCLAW_LOG_DIR:-/var/log/openclaw}
export GATEWAY_PORT=${GATEWAY_PORT:-18791}

mkdir -p "$OPENCLAW_HOME/config" "$OPENCLAW_LOG_DIR"

# 映射为 ~/.openclaw（如果程序认这个）
export HOME=/root
rm -rf /root/.openclaw
ln -s "$OPENCLAW_HOME/config" /root/.openclaw

cd /opt/openclaw/app

# ！！！这里要按真实入口调整 ！！！
# 常见：node server.js / node index.js
nohup node ./index.js --port "$GATEWAY_PORT" >>"$OPENCLAW_LOG_DIR/gateway.log" 2>&1 &

echo "OpenClaw started:"
echo "  http://localhost:${GATEWAY_PORT}"
echo "  log: ${OPENCLAW_LOG_DIR}/gateway.log"
EOF
chmod +x "$ROOTFS_DIR/usr/local/bin/start-openclaw.sh"

# 6) 打包
OUT="${DIST_DIR}/openclaw-debian12-wsl-rootfs-from-source.tar"
tar -C "$ROOTFS_DIR" -cf "$OUT" .
zstd -19 -T0 --rm "$OUT"
echo "Done: ${OUT}.zst"
