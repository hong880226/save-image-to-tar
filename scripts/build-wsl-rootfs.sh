#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(pwd)}"     # 期望当前在 openclaw 仓库根目录
ROOTFS_DIR="/tmp/openclaw-rootfs"
OUT_DIR="${REPO_DIR}/dist"
mkdir -p "$OUT_DIR"
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"

# 1) rootfs: Debian 12 min
sudo apt-get update
sudo apt-get install -y debootstrap zstd tar rsync

sudo debootstrap --variant=minbase bookworm "$ROOTFS_DIR" http://deb.debian.org/debian

# 2) 运行时依赖：这里有一个现实问题
# OpenClaw 若是 Node/TS 运行时服务，最终 WSL rootfs 仍需要 node>=22 才能跑（除非 build 产物是独立二进制）。
# Debian 12 官方源 node 版本不够，所以用 NodeSource 22。
sudo chroot "$ROOTFS_DIR" bash -lc '
set -e
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg tzdata bash tini dumb-init

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
'

# 3) 拷贝构建产物（这里需要你确认：pnpm build/ui:build 产物到底输出到哪）
# 先做“尽量保守”的策略：把常见产物目录复制进去
sudo mkdir -p "$ROOTFS_DIR/opt/openclaw"

copy_if_exists () {
  local src="$1"
  local dst="$2"
  if [[ -e "$src" ]]; then
    sudo mkdir -p "$(dirname "$dst")"
    sudo rsync -a --delete "$src" "$dst"
  fi
}

# 你跑完 pnpm build 后，把下面这些目录按实际产物精简（否则可能偏大）
copy_if_exists "${REPO_DIR}/dist/"        "$ROOTFS_DIR/opt/openclaw/dist/"
copy_if_exists "${REPO_DIR}/packages/"    "$ROOTFS_DIR/opt/openclaw/packages/"
copy_if_exists "${REPO_DIR}/ui/"          "$ROOTFS_DIR/opt/openclaw/ui/"
copy_if_exists "${REPO_DIR}/package.json" "$ROOTFS_DIR/opt/openclaw/package.json"
copy_if_exists "${REPO_DIR}/pnpm-lock.yaml" "$ROOTFS_DIR/opt/openclaw/pnpm-lock.yaml"

# 4) 运行方式选择：为了“稳”，在 rootfs 内执行一次 pnpm 的生产安装（只装运行所需）
# 这会比“复制完整 node_modules”更合理，但仍会让 rootfs 变大。
# 如果 OpenClaw 的发布形态支持“纯 dist 无依赖运行”，我们可以删掉这步。
sudo chroot "$ROOTFS_DIR" bash -lc '
set -e
apt-get update
apt-get install -y --no-install-recommends git
corepack enable
'

# 把工作目录切到 /opt/openclaw 后安装依赖（如果 monorepo，需要按它的方式安装）
# 注意：这一步是否必须，取决于 openclaw build 产物能否脱离 node_modules 运行
sudo chroot "$ROOTFS_DIR" bash -lc '
set -e
cd /opt/openclaw
# 这里假设根目录能安装；如果官方要求在仓库根 pnpm install 才能跑，就保留
pnpm install --prod --frozen-lockfile || true
'

# 5) 配置/日志 + 启动脚本
sudo mkdir -p "$ROOTFS_DIR/var/lib/openclaw/config" "$ROOTFS_DIR/var/log/openclaw"
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

# 这里按你实际产物/启动方式改：
# 如果最终是 CLI：openclaw gateway start ...
# 如果是 pnpm 脚本：pnpm gateway:start ...
# 先给一个保守写法：优先找 openclaw 命令
if command -v openclaw >/dev/null 2>&1; then
  nohup openclaw gateway start --port "$GATEWAY_PORT" >>"$OPENCLAW_LOG_DIR/gateway.log" 2>&1 &
else
  corepack enable >/dev/null 2>&1 || true
  nohup pnpm gateway:start -- --port "$GATEWAY_PORT" >>"$OPENCLAW_LOG_DIR/gateway.log" 2>&1 &
fi

echo "OpenClaw gateway: http://localhost:${GATEWAY_PORT}"
echo "Log: ${OPENCLAW_LOG_DIR}/gateway.log"
EOF
sudo chmod +x "$ROOTFS_DIR/usr/local/bin/start-openclaw.sh"

# 6) 清理瘦身
sudo chroot "$ROOTFS_DIR" bash -lc '
set -e
pnpm store prune || true
rm -rf /root/.cache /home/*/.cache || true
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* || true
'

# 7) 打包
OUT="${OUT_DIR}/openclaw-debian12-wsl-rootfs-node22.tar"
sudo tar -C "$ROOTFS_DIR" -cf "$OUT" .
zstd -19 -T0 --rm "$OUT"
echo "Done: ${OUT}.zst"
