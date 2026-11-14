#!/usr/bin/env bash
# 拉取最新源码，并使用 Docker 在 10004 端口部署。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${DEPLOY_ROOT:-$ROOT}"
cd "$ROOT"

log() { printf '[部署] %s\n' "$*"; }
die() { printf '[部署] 错误：%s\n' "$*" >&2; exit 1; }

valid_ipv4() {
  awk -F. '
    NF != 4 { exit 1 }
    {
      for (part = 1; part <= 4; part++) {
        if ($part !~ /^[0-9]+$/ || $part < 0 || $part > 255) exit 1
      }
    }
  ' <<< "$1"
}

detect_server_ip() {
  local candidate

  for endpoint in https://api.ipify.org https://ipv4.icanhazip.com; do
    if command -v curl >/dev/null 2>&1; then
      candidate="$(curl -4fsS --max-time 4 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)"
    elif command -v wget >/dev/null 2>&1; then
      candidate="$(wget -4 -q -t 1 -T 4 -O - "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)"
    else
      break
    fi
    if valid_ipv4 "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if command -v ip >/dev/null 2>&1; then
    candidate="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
    if valid_ipv4 "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  if command -v hostname >/dev/null 2>&1; then
    candidate="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if valid_ipv4 "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  return 1
}

set_detected_image_url() {
  local image_url="$1"
  local temporary_file

  temporary_file="$(mktemp .env.XXXXXX)"
  awk -v image_url="$image_url" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    {
      lines[NR] = $0
      line = $0
      sub(/^[[:space:]]*/, "", line)
      if (line ~ /^# IMAGE_BASE_URL_AUTO_DETECTED=/) {
        previous_auto_url = substr(line, length("# IMAGE_BASE_URL_AUTO_DETECTED=") + 1)
        metadata_lines[NR] = 1
        next
      }
      sub(/^export[[:space:]]+/, "", line)
      equals = index(line, "=")
      if (equals && trim(substr(line, 1, equals - 1)) == "IMAGE_BASE_URL") {
        assignments[++assignment_count] = NR
        assignment_lines[NR] = 1
        current = trim(substr(line, equals + 1))
        quote = substr(current, 1, 1)
        if (quote == "\"" || quote == "\047") {
          closing_quote = index(substr(current, 2), quote)
          if (closing_quote) current = substr(current, 2, closing_quote - 1)
        } else {
          sub(/[[:space:]]+#.*/, "", current)
        }
        last_value = trim(current)
      }
    }
    END {
      auto_url = assignment_count == 0 || last_value == "" || (previous_auto_url != "" && last_value == previous_auto_url)
      first_assignment = assignment_count ? assignments[1] : 0
      for (line_number = 1; line_number <= NR; line_number++) {
        if (metadata_lines[line_number]) {
          continue
        } else if (auto_url && assignment_lines[line_number]) {
          if (line_number == first_assignment) print "IMAGE_BASE_URL=" image_url
        } else {
          print lines[line_number]
        }
      }
      if (assignment_count == 0 && auto_url) print "IMAGE_BASE_URL=" image_url
      if (auto_url) print "# IMAGE_BASE_URL_AUTO_DETECTED=" image_url
    }
  ' .env > "$temporary_file"
  chmod 600 "$temporary_file"
  mv "$temporary_file" .env
}

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

SERVER_IP="$(detect_server_ip || true)"
if [ -n "$SERVER_IP" ]; then
  log "探测到服务器 IP: $SERVER_IP"
  set_detected_image_url "http://$SERVER_IP:10004"
else
  SERVER_IP=127.0.0.1
  log "无法自动探测服务器 IP，将使用本机地址显示部署 URL"
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
docker compose up -d --force-recreate --remove-orphans

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
log "管理界面: http://$SERVER_IP:10004"
log "OpenAI 兼容接口: http://$SERVER_IP:10004/v1"
log "随机凭据已保存到 .env"
log "查看日志: docker compose logs -f"
