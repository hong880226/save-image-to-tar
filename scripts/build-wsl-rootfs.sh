#!/usr/bin/env bash
set -euo pipefail

ROOTFS_DIR="/tmp/openclaw-rootfs"
OUT_DIR="${OUT_DIR:-${GITHUB_WORKSPACE:-$(pwd)}/dist}"
OPENCLAW_VERSION="${OPENCLAW_VERSION:-latest}"   # 可传 v2026.3.9 或 latest/beta/dev
GATEWAY_PORT="${GATEWAY_PORT:-18789}"

mkdir -p "$OUT_DIR"
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"

# 1) base rootfs
sudo apt-get update
sudo apt-get install -y debootstrap zstd tar curl gnupg ca-certificates

sudo debootstrap --variant=minbase bookworm "$ROOTFS_DIR" http://deb.debian.org/debian

# 2) install Node >= 22 (NodeSource) + basic runtime tools
sudo chroot "$ROOTFS_DIR" bash -lc '
set -e
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg tzdata bash tini dumb-init \
  iproute2 procps openssl

ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone

# NodeSource 22.x
mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
  | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
  > /etc/apt/sources.list.d/nodesource.list

apt-get update
apt-get install -y --no-install-recommends nodejs
node -v
npm -v
'

# 3) install openclaw globally (official recommended)
#    这里用 npm，避免 pnpm workspace/TTY 问题
sudo chroot "$ROOTFS_DIR" bash -lc "
set -e
export CI=true
npm config set fund false
npm config set audit false
npm install -g openclaw@${OPENCLAW_VERSION}
command -v openclaw
openclaw --help >/dev/null || true
"

# 4) persistent dirs + start script (WSL-friendly, no systemd required)
sudo mkdir -p "$ROOTFS_DIR/var/lib/openclaw" "$ROOTFS_DIR/var/log/openclaw" "$ROOTFS_DIR/usr/local/bin"

sudo tee "$ROOTFS_DIR/usr/local/bin/start-openclaw.sh" >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail

export TZ=Asia/Shanghai
export OPENCLAW_HOME=\${OPENCLAW_HOME:-/var/lib/openclaw}
export OPENCLAW_LOG_DIR=\${OPENCLAW_LOG_DIR:-/var/log/openclaw}
export GATEWAY_PORT=\${GATEWAY_PORT:-${GATEWAY_PORT}}

mkdir -p "\$OPENCLAW_HOME" "\$OPENCLAW_LOG_DIR"

# OpenClaw 默认使用 ~/.openclaw
export HOME=/root
rm -rf /root/.openclaw || true
ln -s "\$OPENCLAW_HOME" /root/.openclaw

# 启动 gateway（README Quick start）
nohup openclaw gateway --port "\$GATEWAY_PORT" --verbose \\
  >>"\$OPENCLAW_LOG_DIR/gateway.log" 2>&1 &

echo "OpenClaw gateway: http://localhost:\$GATEWAY_PORT"
echo "Log: \$OPENCLAW_LOG_DIR/gateway.log"
EOF
sudo chmod +x "$ROOTFS_DIR/usr/local/bin/start-openclaw.sh"

# 5) optional: onboard helper (you run it after import)
sudo tee "$ROOTFS_DIR/usr/local/bin/openclaw-onboard.sh" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export HOME=/root
mkdir -p /var/lib/openclaw /var/log/openclaw
rm -rf /root/.openclaw || true
ln -s /var/lib/openclaw /root/.openclaw

# WSL 里不一定有 systemd user session；先不强推 --install-daemon
# 你如果已启用 systemd，可手动加 --install-daemon
openclaw onboard
EOF
sudo chmod +x "$ROOTFS_DIR/usr/local/bin/openclaw-onboard.sh"

# 6) cleanup
sudo chroot "$ROOTFS_DIR" bash -lc '
set -e
npm cache clean --force || true
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* || true
'

# 7) pack
OUT="$OUT_DIR/openclaw-debian12-wsl-rootfs-node22-openclaw-${OPENCLAW_VERSION}.tar"
sudo tar -C "$ROOTFS_DIR" -cf "$OUT" .
zstd -19 -T0 --rm "$OUT"
echo "[OK] $OUT.zst"
