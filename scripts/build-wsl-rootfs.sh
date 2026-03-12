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

# none | chromium
# chromium = 安装 chromium，并提供 headless wrapper 给 openclaw 使用（默认）
BROWSER_MODE="${BROWSER_MODE:-chromium}"

mkdir -p "$OUT_DIR"
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"

echo "[i] OPENCLAW_VERSION=$OPENCLAW_VERSION"
echo "[i] GATEWAY_PORT=$GATEWAY_PORT"
echo "[i] LLAMA_MODE=$LLAMA_MODE"
echo "[i] BROWSER_MODE=$BROWSER_MODE"

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

# 2) browser: chromium (headless, for openclaw only)
if [[ "$BROWSER_MODE" == "chromium" ]]; then
  sudo chroot "$ROOTFS_DIR" bash -lc '
set -e
apt-get update
apt-get install -y --no-install-recommends \
  chromium \
  # 常见 headless 依赖/字体（减少渲染/启动问题）
  fonts-noto-cjk fonts-noto-color-emoji \
  libasound2 libgbm1 libgtk-3-0 libnss3 libxss1 libxshmfence1 \
  xdg-utils

chromium --version || true
'
fi

# 3) optional build toolchain for llama.cpp
if [[ "$LLAMA_MODE" == "build-soft" || "$LLAMA_MODE" == "build-hard" ]]; then
  sudo chroot "$ROOTFS_DIR" bash -lc '
set -e
apt-get update
apt-get install -y --no-install-recommends \
  build-essential make cmake python3 pkg-config
'
fi

# 4) install openclaw globally (always ignore scripts to keep CI reliable)
sudo chroot "$ROOTFS_DIR" bash -lc "
set -e
export CI=true
npm config set fund false
npm config set audit false
npm install -g openclaw@${OPENCLAW_VERSION} --ignore-scripts
command -v openclaw
openclaw --help >/dev/null || true
"

# 5) if build-soft/build-hard: try to enable llama.cpp (best-effort or strict)
if [[ "$LLAMA_MODE" == "build-soft" || "$LLAMA_MODE" == "build-hard" ]]; then
  if [[ "$LLAMA_MODE" == "build-hard" ]]; then
    sudo chroot "$ROOTFS_DIR" bash -lc "
set -e
export CI=true
npm rebuild -g node-llama-cpp
"
  else
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

# 6) persistent dirs + helper scripts
sudo mkdir -p "$ROOTFS_DIR/var/lib/openclaw" "$ROOTFS_DIR/var/log/openclaw" "$ROOTFS_DIR/usr/local/bin"

# 6.1 headless chromium wrapper (stable path)
if [[ "$BROWSER_MODE" == "chromium" ]]; then
  sudo tee "$ROOTFS_DIR/usr/local/bin/openclaw-chromium" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# OpenClaw headless browser wrapper
# Notes:
# - --no-sandbox: 在部分 WSL/容器环境是必须的；如果你确认 sandbox 正常，可删除
# - --headless=new: Chromium 新 headless
# - --disable-dev-shm-usage: 避免 /dev/shm 太小导致崩溃
exec /usr/bin/chromium \
  --headless=new \
  --disable-gpu \
  --no-sandbox \
  --disable-dev-shm-usage \
  --remote-debugging-port=0 \
  "$@"
EOF
  sudo chmod +x "$ROOTFS_DIR/usr/local/bin/openclaw-chromium"

  # 给 OpenClaw 提供一个约定的 env（你也可以在 openclaw.json 里指向该路径）
  sudo mkdir -p "$ROOTFS_DIR/etc/profile.d"
  sudo tee "$ROOTFS_DIR/etc/profile.d/openclaw-browser.sh" >/dev/null <<'EOF'
export OPENCLAW_BROWSER_BIN=${OPENCLAW_BROWSER_BIN:-/usr/local/bin/openclaw-chromium}
EOF
fi

# 6.2 start/openboard
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

# 确保 openclaw 能看到浏览器 wrapper（profile.d 只对交互 shell 生效，这里显式导出）
EOF

if [[ "$BROWSER_MODE" == "chromium" ]]; then
  sudo tee -a "$ROOTFS_DIR/usr/local/bin/start-openclaw.sh" >/dev/null <<'EOF'
export OPENCLAW_BROWSER_BIN=${OPENCLAW_BROWSER_BIN:-/usr/local/bin/openclaw-chromium}
EOF
fi

sudo tee -a "$ROOTFS_DIR/usr/local/bin/start-openclaw.sh" >/dev/null <<'EOF'

nohup openclaw gateway --port "$GATEWAY_PORT" --verbose \
  >>"$OPENCLAW_LOG_DIR/gateway.log" 2>&1 &

echo "OpenClaw gateway: http://localhost:${GATEWAY_PORT}"
echo "Log: ${OPENCLAW_LOG_DIR}/gateway.log"
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
npm rebuild -g node-llama-cpp
echo "[OK] llama.cpp backend enabled."
EOF
  sudo chmod +x "$ROOTFS_DIR/usr/local/bin/openclaw-enable-llama.sh"
fi

# 7) cleanup
sudo chroot "$ROOTFS_DIR" bash -lc '
set -e
npm cache clean --force || true
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* || true
'

# 8) pack
OUT="$OUT_DIR/openclaw-debian12-wsl-rootfs-node22-openclaw-${OPENCLAW_VERSION}-llama-${LLAMA_MODE}-browser-${BROWSER_MODE}.tar"
sudo tar -C "$ROOTFS_DIR" -cf "$OUT" .
zstd -19 -T0 --rm "$OUT"
echo "[OK] $OUT.zst"
