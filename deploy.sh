#!/usr/bin/env bash
# 拉取最新源码，并使用 Docker 在 10004 端口部署。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${DEPLOY_ROOT:-$ROOT}"
cd "$ROOT"

log() { printf '[部署] %s\n' "$*"; }
die() { printf '[部署] 错误：%s\n' "$*" >&2; exit 1; }

if [ "${DEPLOY_FROM_COPY:-0}" != "1" ]; then
  SCRIPT_COPY="$(mktemp "${TMPDIR:-/tmp}/antigravity2api-deploy.XXXXXX")"
  trap 'rm -f "$SCRIPT_COPY"' EXIT
  cp "$ROOT/deploy.sh" "$SCRIPT_COPY"
  DEPLOY_ROOT="$ROOT" DEPLOY_FROM_COPY=1 bash "$SCRIPT_COPY"
  exit $?
fi

command -v git >/dev/null 2>&1 || die "git is required"
command -v docker >/dev/null 2>&1 || die "Docker is required"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required"
docker info >/dev/null 2>&1 || die "Docker is not running or the current user cannot access it"

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
  log "恢复本地修改"
  git stash pop || die "恢复本地修改时发生冲突，请解决后重新执行 ./deploy.sh"
fi

if [ "$BEFORE" != "$(git rev-parse HEAD)" ] && [ "${DEPLOY_REEXEC:-0}" != "1" ]; then
  log "源码已更新，使用最新部署脚本继续"
  LATEST_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/antigravity2api-deploy.XXXXXX")"
  trap 'rm -f "$LATEST_SCRIPT"' EXIT
  git show HEAD:deploy.sh > "$LATEST_SCRIPT" || die "无法读取最新 deploy.sh"
  DEPLOY_ROOT="$ROOT" DEPLOY_REEXEC=1 bash "$LATEST_SCRIPT"
  exit $?
fi

if [ ! -f .env ]; then
  cp .env.example .env
  log "已从 .env.example 创建 .env"
fi

if [ ! -f config.json ]; then
  cp config.json.example config.json
  log "已从 config.json.example 创建 config.json"
fi

if [ ! -f security.json ]; then
  cp security.json.example security.json
  log "已从 security.json.example 创建 security.json"
fi

mkdir -p data public/images

log "构建 Docker 镜像..."
docker compose build

stop_legacy_node() {
  local pid
  local process_command

  [ -f .deploy.pid ] || return 0
  pid="$(tr -d '[:space:]' < .deploy.pid)"
  case "$pid" in
    ''|*[!0-9]*) die ".deploy.pid 中的进程号无效，拒绝停止进程" ;;
  esac
  [ "$pid" -gt 1 ] || die ".deploy.pid 中的进程号无效，拒绝停止进程"

  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f .deploy.pid
    return 0
  fi

  process_command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$process_command" in
    *"node --expose-gc $ROOT/src/server/index.js")
      log "停止本项目旧版 Node 服务 (PID $pid)"
      kill "$pid"
      for _ in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
      done
      kill -0 "$pid" 2>/dev/null && die "旧版服务未能退出，请检查 PID $pid"
      rm -f .deploy.pid
      ;;
    *) die ".deploy.pid 指向其他进程，拒绝停止: ${process_command:-PID $pid}" ;;
  esac
}

stop_legacy_node
log "启动 Docker 容器..."
docker compose up -d --remove-orphans

ready=0
for _ in $(seq 1 60); do
  container_id="$(docker compose ps -a -q antigravity2api 2>/dev/null || true)"
  if [ -n "$container_id" ]; then
    state="$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container_id" 2>/dev/null || true)"
  else
    state=""
  fi

  case "$state" in
    "running healthy")
      ready=1
      break
      ;;
    "exited "*|"dead "*|"removing "*)
      docker compose logs --tail=60 antigravity2api >&2 || true
      die "Container failed to start"
      ;;
  esac

  sleep 1
done

if [ "$ready" -ne 1 ]; then
  docker compose logs --tail=60 antigravity2api >&2 || true
  die "Container did not become healthy; check Docker Compose logs"
fi

log "部署完成"
log "管理界面: http://127.0.0.1:10004"
log "OpenAI 兼容接口: http://127.0.0.1:10004/v1"
log "随机凭据已保存到 .env"
log "查看日志: docker compose logs -f"
