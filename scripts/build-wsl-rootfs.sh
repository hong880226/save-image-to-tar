#!/usr/bin/env bash
set -euo pipefail

ROOTFS_DIR="/tmp/openclaw-rootfs"
OUT_DIR="${OUT_DIR:-${GITHUB_WORKSPACE:-$(pwd)}/dist}"

OPENCLAW_VERSION="${OPENCLAW_VERSION:-latest}"   # latest / beta / dev / 2026.3.9 ...
GATEWAY_PORT="${GATEWAY_PORT:-18789}"

# off   = 方案A：跳过 npm scripts（最稳，不编译 node-llama-cpp）
# build = 方案B：安装 cmake/make/g++ 等，允许 postinstall 编译 llama.cpp
LLAMA_MODE="${LLAMA_MODE:-off}"

mkdir -p "$OUT_DIR"
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"

echo "[i] OPENCLAW_VERSION=$OPENCLAW_VERSION"
echo "[i] GATEWAY_PORT=$GATEWAY_PORT"
echo "[i] LLAMA_MODE=$LLAMA_MODE"

sudo apt-get update
sudo apt-get install -y debootstrap zstd tar curl gnupg ca-certificates

sudo debootstrap --variant=minbase bookworm "$ROOTFS_DIR" http://deb.debian.org/debian

# 1) base runtime deps + Node 22 + git (npm tree may use git)
sudo chroot "$ROOTFS_DIR" bash -lc '
set -e
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg tzdata bash tini dumb-init \
  iproute2 procps openssl \
  git openssh-client

ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone

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

# 2) optional build toolchain (方案B)
if [[ "$LLAMA_MODE" == "build" ]]; then
  sudo chroot "$ROOTFS_DIR" bash -lc '
set -e
apt-get update
apt-get install -y --no-install-recommends \
  build-essential make cmake python3 pkg-config
'
fi

# 3) install openclaw
# 方案A：--ignore-scripts（跳过 node-llama-cpp postinstall）
# 方案B：正常安装（允许 postinstall 编译）
if [[ "$LLAMA_MODE" == "off" ]]; then
  INSTALL_FLAGS="--ignore-scripts"
else
  INSTALL_FLAGS=""
fi

sudo chroot "$ROOTFS_DIR" bash -lc "
set -e
export CI=true
npm config set fund false
npm config set audit false
npm install -g openclaw@${OPENCLAW_VERSION} ${INSTALL_FLAGS}
command -v openclaw
openclaw --help >/dev/null || true
"

# 4) persistent dirs + start script
sudo mkdir -p "$ROOTFS_DIR/var/lib/openclaw" "$ROOTFS_DIR/var/log/openclaw" "$ROOTFS_DIR/usr/local/bin"

sudo tee "$ROOTFS_DIR/usr/local/bin/start-openclaw.sh" >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail

export TZ=Asia/Shanghai
export OPENCLAW_HOME=\${OPENCLAW_HOME:-/var/lib/openclaw}
export OPENCLAW_LOG_DIR=\${OPENCLAW_LOG_DIR:-/var/log/openclaw}
export GATEWAY_PORT=\${GATEWAY_PORT:-${GATEWAY_PORT}}

mkdir -p "\$OPENCLAW_HOME" "\$OPENCLAW_LOG_DIR"

export HOME=/root
rm -rf /root/.openclaw || true
ln -s "\$OPENCLAW_HOME" /root/.openclaw

nohup openclaw gateway --port "\$GATEWAY_PORT" --verbose \\
  >>"\$OPENCLAW_LOG_DIR/gateway.log" 2>&1 &

echo "OpenClaw gateway: http://localhost:\$GATEWAY_PORT"
echo "Log: \$OPENCLAW_LOG_DIR/gateway.log"
EOF
sudo chmod +x "$ROOTFS_DIR/usr/local/bin/start-openclaw.sh"

sudo tee "$ROOTFS_DIR/usr/local/bin/openclaw-onboard.sh" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export HOME=/root
mkdir -p /var/lib/openclaw /var/log/openclaw
rm -rf /root/.openclaw || true
ln -s /var/lib/openclaw /root/.openclaw
openclaw onboard
EOF
sudo chmod +x "$ROOTFS_DIR/usr/local/bin/openclaw-onboard.sh"

# 5) cleanup
sudo chroot "$ROOTFS_DIR" bash -lc '
set -e
npm cache clean --force || true
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* || true
'

# 6) pack
OUT="$OUT_DIR/openclaw-debian12-wsl-rootfs-node22-openclaw-${OPENCLAW_VERSION}-llama-${LLAMA_MODE}.tar"
sudo tar -C "$ROOTFS_DIR" -cf "$OUT" .
zstd -19 -T0 --rm "$OUT"
echo "[OK] $OUT.zst"
