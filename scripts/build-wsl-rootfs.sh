#!/usr/bin/env bash
set -euo pipefail

# openclaw 源码目录（workflow 里用 env 传 REPO_DIR=.../openclaw-src）
REPO_DIR="${REPO_DIR:-$(pwd)}"

ROOTFS_DIR="/tmp/openclaw-rootfs"
OUT_DIR="${REPO_DIR}/dist"
mkdir -p "$OUT_DIR"
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"

echo "[i] REPO_DIR=$REPO_DIR"

# ---------- 0) sanity check ----------
if [[ ! -f "$REPO_DIR/package.json" ]]; then
  echo "[!] package.json not found under REPO_DIR"
  exit 1
fi
if [[ ! -f "$REPO_DIR/pnpm-lock.yaml" ]]; then
  echo "[!] pnpm-lock.yaml not found under REPO_DIR (pnpm workspace expected)"
  exit 1
fi

# 关键：确保 scripts/run-node.mjs 存在（你遇到的问题就是它丢了）
if [[ ! -f "$REPO_DIR/scripts/run-node.mjs" ]]; then
  echo "[!] scripts/run-node.mjs not found under REPO_DIR"
  echo "    This file is required by: node scripts/run-node.mjs ..."
  echo "    Please ensure you are copying the full repo (not partial dist/packages/ui only)."
  exit 1
fi

# ---------- 1) minimal Debian rootfs ----------
sudo apt-get update
sudo apt-get install -y debootstrap zstd tar rsync curl gnupg

sudo debootstrap --variant=minbase bookworm "$ROOTFS_DIR" http://deb.debian.org/debian

# ---------- 2) install runtime deps (Node >=22 + tini) ----------
sudo chroot "$ROOTFS_DIR" bash -lc '
set -e
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg tzdata bash tini dumb-init \
  iproute2 procps

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

# pnpm via corepack, and pin a version (避免每次启动都去下载)
corepack enable
corepack prepare pnpm@10.32.1 --activate
pnpm -v
'

# ---------- 3) copy openclaw repo (built) into /opt/openclaw ----------
# 这里是关键修复：整体同步（保留 scripts/），但排除 .git 等无用内容
sudo mkdir -p "$ROOTFS_DIR/opt/openclaw"

sudo rsync -a --delete \
  --exclude ".git/" \
  --exclude ".github/" \
  --exclude ".turbo/" \
  --exclude ".cache/" \
  --exclude ".pnpm-store/" \
  --exclude "node_modules/.cache/" \
  --exclude "**/*.log" \
  "$REPO_DIR/" \
  "$ROOTFS_DIR/opt/openclaw/"

# ---------- 4) (optional but recommended) ensure deps are present in rootfs ----------
# 你现在的 rootfs 里已经出现 node_modules，说明你把它带进去了。
# 为了“可运行”，我们这里采取保守策略：在 rootfs 内再执行一次 pnpm install（有 lockfile）
# 如果你想减小体积，后续可改成只带 production 依赖或做 pnpm deploy。
sudo chroot "$ROOTFS_DIR" bash -lc '
set -e
cd /opt/openclaw
corepack enable
corepack prepare pnpm@10.32.1 --activate
pnpm install --frozen-lockfile
'

# ---------- 5) create data dirs + start script ----------
sudo mkdir -p "$ROOTFS_DIR/var/lib/openclaw/config" "$ROOTFS_DIR/var/log/openclaw"
sudo mkdir -p "$ROOTFS_DIR/usr/local/bin"

sudo tee "$ROOTFS_DIR/usr/local/bin/start-openclaw.sh" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export TZ=Asia/Shanghai
export OPENCLAW_HOME=${OPENCLAW_HOME:-/var/lib/openclaw}
export OPENCLAW_LOG_DIR=${OPENCLAW_LOG_DIR:-/var/log/openclaw}
export GATEWAY_PORT=${GATEWAY_PORT:-18791}

mkdir -p "$OPENCLAW_HOME/config" "$OPENCLAW_LOG_DIR"

export HOME=/root
rm -rf /root/.openclaw
ln -s "$OPENCLAW_HOME/config" /root/.openclaw

cd /opt/openclaw

# 先用你已验证存在的命令：gateway:dev
# 若后续确认有 prod/start，再换成 gateway:start/serve 等
nohup pnpm gateway:dev -- --port "$GATEWAY_PORT" >>"$OPENCLAW_LOG_DIR/gateway.log" 2>&1 &

echo "OpenClaw gateway: http://localhost:${GATEWAY_PORT}"
echo "Log: ${OPENCLAW_LOG_DIR}/gateway.log"
EOF
sudo chmod +x "$ROOTFS_DIR/usr/local/bin/start-openclaw.sh"

# ---------- 6) cleanup (keep moderate size, but don't break runtime) ----------
sudo chroot "$ROOTFS_DIR" bash -lc '
set -e
pnpm store prune || true
rm -rf /root/.cache /home/*/.cache || true
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* || true
'

# ---------- 7) pack ----------
OUT="$OUT_DIR/openclaw-debian12-wsl-rootfs-node22.tar"
sudo tar -C "$ROOTFS_DIR" -cf "$OUT" .
zstd -19 -T0 --rm "$OUT"
echo "[OK] $OUT.zst"
