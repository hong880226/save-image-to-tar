#!/usr/bin/env bash
set -euo pipefail

ROOTFS_DIR="/tmp/openclaw-rootfs"
OUT_DIR="${OUT_DIR:-${GITHUB_WORKSPACE:-$(pwd)}/dist}"

OPENCLAW_VERSION="${OPENCLAW_VERSION:-latest}"   # latest / beta / dev / 2026.3.9 ...
GATEWAY_PORT="${GATEWAY_PORT:-18789}"

# off        = 默认最稳：跳过 npm scripts（不触发 node-llama-cpp postinstall）
# build-soft = 安装编译链，尝试启用 llama（失败不阻塞），并生成 enable 脚本
# build-hard = 强制在 CI/chroot 内构建成功（失败则退出）
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

# 2) optional build toolchain for llama.cpp
if [[ "$LLAMA_MODE" == "build-soft" || "$LLAMA_MODE" == "build-hard" ]]; then
  sudo chroot "$ROOTFS_DIR" bash -lc '
set -e
apt-get update
apt-get install -y --no-install-recommends \
  build-essential make cmake python3 pkg-config
'
fi

# 3) install openclaw globally
# 关键：为保证“可靠打包”，这里永远用 --ignore-scripts，避免 node-llama-cpp postinstall 在 chroot 崩溃
sudo chroot "$ROOTFS_DIR" bash -lc "
set -e
export CI=true
npm config set fund false
npm config set audit false
npm install -g openclaw@${OPENCLAW_VERSION} --ignore-scripts
command -v openclaw
openclaw --help >/dev/null || true
"

# 4) if build-soft/build-hard: try to enable llama.cpp (best-effort or strict)
if [[ "$LLAMA_MODE" == "build-soft" || "$LLAMA_MODE" == "build-hard" ]]; then
  if [[ "$LLAMA_MODE" == "build-hard" ]]; then
    # strict: fail job if llama cannot be enabled inside chroot
    sudo chroot "$ROOTFS_DIR" bash -lc "
set -e
export CI=true
npm rebuild -g node-llama-cpp
"
  else
    # soft: do not fail job
    set +e
    sudo chroot "$ROOTFS_DIR" bash -lc "
set -e
export CI=true
npm rebuild -g node-llama-cpp
"
    RC=$?
    set -e
    if [[ $RC -ne 0 ]]; then
      echo "[warn] node-llama-cpp rebuild failed in chroot (expected on some CI/chroot envs)."
      echo "[warn] You can enable it after import via: /usr/local/bin/openclaw-enable-llama.sh"
    fi
  fi
fi

# 5) persistent dirs + start scripts
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

# 仅当你选择 build-soft/build-hard 时，提供导入后启用 llama 的脚本
if [[ "$LLAMA_MODE" == "build-soft" || "$LLAMA_MODE" == "build-hard" ]]; then
  sudo tee "$ROOTFS_DIR/usr/local/bin/openclaw-enable-llama.sh" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export CI=true

apt-get update
apt-get install -y --no-install-recommends build-essential make cmake python3 pkg-config

# 重新构建 node-llama-cpp（在真实 WSL 环境里比 chroot/CI 更容易通过其自检）
npm rebuild -g node-llama-cpp

echo "[OK] llama.cpp backend enabled."
EOF
  sudo chmod +x "$ROOTFS_DIR/usr/local/bin/openclaw-enable-llama.sh"
fi

# 6) cleanup
sudo chroot "$ROOTFS_DIR" bash -lc '
set -e
npm cache clean --force || true
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* || true
'

# 7) pack
OUT="$OUT_DIR/openclaw-debian12-wsl-rootfs-node22-openclaw-${OPENCLAW_VERSION}-llama-${LLAMA_MODE}.tar"
sudo tar -C "$ROOTFS_DIR" -cf "$OUT" .
zstd -19 -T0 --rm "$OUT"
echo "[OK] $OUT.zst"
