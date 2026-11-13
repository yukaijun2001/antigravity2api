#!/usr/bin/env bash
# 一键部署：拉取当前分支最新源码，安装依赖，并在 10004 端口启动服务。
set -euo pipefail

PORT="${PORT:-10004}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${DEPLOY_FROM_COPY:-0}" != "1" ]; then
  COPY="$(mktemp "${TMPDIR:-/tmp}/antigravity2api-deploy.XXXXXX")"
  cp "$ROOT/deploy.sh" "$COPY"
  DEPLOY_ROOT="$ROOT" DEPLOY_FROM_COPY=1 exec bash "$COPY"
fi
ROOT="${DEPLOY_ROOT:-$ROOT}"
PID_FILE="$ROOT/.deploy.pid"
LOG_FILE="$ROOT/logs/deploy.log"
cd "$ROOT"

log() { printf '[deploy] %s\n' "$*"; }
die() { printf '[deploy] 错误: %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "未找到 git"
command -v node >/dev/null 2>&1 || die "未找到 Node.js，需要 >= 18"
command -v npm >/dev/null 2>&1 || die "未找到 npm"

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 18 ] || die "需要 Node.js >= 18，当前为 $(node -v)"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" != "HEAD" ] || BRANCH="main"

log "拉取 origin/$BRANCH 最新源码..."
BEFORE="$(git rev-parse HEAD)"
git fetch origin "$BRANCH"

STASHED=0
if ! git diff --quiet || ! git diff --cached --quiet; then
  log "暂存已跟踪文件的本地修改"
  git stash push -m "deploy.sh auto stash $(date +%Y%m%d%H%M%S)"
  STASHED=1
fi

git pull --ff-only origin "$BRANCH"

if [ "$STASHED" -eq 1 ]; then
  log "尝试恢复本地修改"
  git stash pop || die "恢复本地修改时发生冲突，请处理后重新执行 ./deploy.sh"
fi

AFTER="$(git rev-parse HEAD)"
if [ "$BEFORE" != "$AFTER" ] && [ "${DEPLOY_REEXEC:-0}" != "1" ]; then
  log "源码已更新，使用新脚本继续部署"
  DEPLOY_REEXEC=1 DEPLOY_FROM_COPY=0 exec "$ROOT/deploy.sh"
fi

log "安装生产依赖..."
if [ -f package-lock.json ]; then
  npm ci --omit=dev
else
  npm install --omit=dev
fi

if [ ! -f .env ]; then
  cp .env.example .env
  log "已从 .env.example 创建 .env"
fi

mkdir -p data logs public/images

log "将服务端口设置为 $PORT"
DEPLOY_PORT="$PORT" node --input-type=module <<'EOF'
import fs from 'node:fs';

const port = Number(process.env.DEPLOY_PORT);
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  console.error(`[deploy] 错误: 无效端口 ${process.env.DEPLOY_PORT}`);
  process.exit(1);
}

let config = {};
if (fs.existsSync('config.json')) {
  config = JSON.parse(fs.readFileSync('config.json', 'utf8'));
} else if (fs.existsSync('config.json.example')) {
  config = JSON.parse(fs.readFileSync('config.json.example', 'utf8'));
}

config.server ??= {};
config.server.port = port;
config.server.host ||= '0.0.0.0';
fs.writeFileSync('config.json', `${JSON.stringify(config, null, 2)}\n`);
EOF

stop_pid() {
  local pid="$1"
  local command
  case "$pid" in
    ''|*[!0-9]*) die "无效的部署进程 PID: $pid" ;;
  esac
  [ "$pid" -gt 1 ] || die "无效的部署进程 PID: $pid"
  kill -0 "$pid" 2>/dev/null || return 0
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$command" in
    *"node --expose-gc $ROOT/src/server/index.js") ;;
    *) die "PID $pid 不属于当前项目，已停止部署" ;;
  esac
  kill "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.3
  done
  kill -9 "$pid" 2>/dev/null || true
}

if [ -f "$PID_FILE" ]; then
  log "停止已部署的进程"
  stop_pid "$(cat "$PID_FILE" 2>/dev/null || true)"
  rm -f "$PID_FILE"
fi

if command -v lsof >/dev/null 2>&1; then
  while read -r pid; do
    [ -n "$pid" ] || continue
    cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    die "端口 $PORT 已被其他进程占用: ${cmd:-pid $pid}"
  done < <(lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)
fi

log "启动服务..."
: > "$LOG_FILE"
nohup node --expose-gc "$ROOT/src/server/index.js" </dev/null >>"$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"

ready=0
for _ in $(seq 1 30); do
  if ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    tail -n 40 "$LOG_FILE" >&2 || true
    die "服务进程已退出，详见 $LOG_FILE"
  fi
  if node -e "fetch('http://127.0.0.1:'+process.argv[1]+'/').then(r=>process.exit(r.status<500?0:1)).catch(()=>process.exit(1))" "$PORT" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.5
done

[ "$ready" -eq 1 ] || die "服务启动超时，详见 $LOG_FILE"

log "部署完成"
log "管理界面: http://127.0.0.1:$PORT"
log "OpenAI 兼容接口: http://127.0.0.1:$PORT/v1"
log "日志: $LOG_FILE"
