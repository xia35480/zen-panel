#!/usr/bin/env bash
# 在 GitHub Actions runner 上跑 zen-console：
#   恢复密文状态 → 起面板 → 起 Cloudflare 命名隧道 → 守护 → 周期快照 → 到点交班。
# 关键约束：
#   * 同一个 concurrency group 里只允许一个实例（同名隧道双连接会被 CF 轮询，表现为随机 502）。
#   * 公有库的 release 资产是公开的，所以 state 必须密文（PANEL_STATE_KEY）。
#   * 任何会打印 token 的动作都不做；需要打印时先 ::add-mask::。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
BIN="$ROOT/bin"
RUN="$ROOT/run"
STATE_DIR="$ROOT/state"
mkdir -p "$RUN" "$STATE_DIR" "$RUN/upload" "$RUN/prev"
rm -f "$RUN/dispatched" "$RUN/no-handoff"
date +%s >"$RUN/started-epoch.txt"

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { log "::error::$*"; printf '%s\n' "$*" >"$RUN/no-handoff"; exit 1; }

sanitize() {
  local line secret
  line=$(cat)
  for secret in "${CF_TUNNEL_TOKEN:-}" "${PANEL_TOKEN:-}" "${ZEN_API_KEY:-}" \
    "${PANEL_STATE_KEY:-}" "${GH_TOKEN:-}"; do
    [ -n "$secret" ] && line="${line//"$secret"/***}"
  done
  printf '%s\n' "$line" | sed -E \
    -e 's/(ghp_[A-Za-z0-9]+)/ghp_***/g' \
    -e 's/(github_pat_[A-Za-z0-9_]+)/github_pat_***/g' \
    -e 's/([Bb]earer[[:space:]]+)[A-Za-z0-9._~+\/=-]+/\1***/g' \
    -e 's/((TOKEN|token|SECRET|secret)[=:][[:space:]]*)[^[:space:]"]+/\1***/g'
}

PORT="${PANEL_PORT:-8081}"
PUBLIC_HOST="${ZEN_PUBLIC_HOST:-}"
PUBLIC_HOST="${PUBLIC_HOST#https://}"
PUBLIC_HOST="${PUBLIC_HOST#http://}"
PUBLIC_HOST="${PUBLIC_HOST%/}"
RELEASE_TAG="${STATE_RELEASE:-panel-state}"
STATE_ASSET="${STATE_ASSET:-state.bin}"
STATE_PREV_ASSET="${STATE_PREV_ASSET:-state.prev.bin}"
STATE_FILE="$STATE_DIR/$STATE_ASSET"
PANEL_LOG="$RUN/panel.log"
CF_LOG="$RUN/cloudflared.log"

LOCAL_TIMEOUT=120
PUBLIC_TIMEOUT=90
SNAPSHOT_INTERVAL=300
RESTART_WINDOW=1800
RESTART_LIMIT=6

PANEL_PID=""
CF_PID=""
PANEL_READY=0
FINAL_SNAPSHOT_DONE=0
panel_restart_total=0
panel_restarts=()

# 公开仓库的 job 日志是所有人可见的。域名本身能通过 DNS/证书透明日志查到，
# 但没必要主动写在日志里被人顺手扫到；统一打码，后续出现的地方都会变成 ***。
if [ -n "$PUBLIC_HOST" ]; then
  printf '::add-mask::%s\n' "$PUBLIC_HOST"
fi

raw_ttl="${MAX_RUN_SEC:-18000}"
if [[ "$raw_ttl" =~ ^-?[0-9]{1,9}$ ]]; then
  TTL=$((10#${raw_ttl#-}))
  if [ "${raw_ttl:0:1}" = "-" ]; then
    TTL=$((-TTL))
  fi
else
  log "::warning::MAX_RUN_SEC 非法（${raw_ttl:0:20}），回退 18000"
  TTL=18000
fi
if [ "$TTL" -lt 600 ]; then
  log "::warning::MAX_RUN_SEC=${TTL} 过小，clamp 到 600"
  TTL=600
fi
if [ "$TTL" -gt 19800 ]; then
  log "::warning::MAX_RUN_SEC=${TTL} 过大，clamp 到 19800"
  TTL=19800
fi

if [[ ! "$PORT" =~ ^[0-9]{1,5}$ ]]; then
  die "PANEL_PORT 不是合法端口：$PORT"
fi
PORT=$((10#$PORT))
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  die "PANEL_PORT 超出范围：$PORT"
fi
PANEL="http://127.0.0.1:$PORT"

for v in CF_TUNNEL_TOKEN PANEL_TOKEN ZEN_API_KEY ZEN_ACCOUNTS_JSON PANEL_STATE_KEY GH_TOKEN GITHUB_REPOSITORY; do
  [ -n "${!v:-}" ] || die "缺少必需 secret/env: $v"
done

unset ZEN_STATE_IMPORT

local_code() {
  curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 3 "$PANEL/api/healthz" 2>/dev/null || true
}

public_code() {
  [ -n "$PUBLIC_HOST" ] || { printf '000'; return 1; }
  curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 10 "https://$PUBLIC_HOST/api/healthz" 2>/dev/null || true
}

release_status() {
  timeout 30 gh api --include --jq '.id' \
    "repos/${GITHUB_REPOSITORY:?}/releases/tags/${RELEASE_TAG}" 2>&1 \
    | sed -n '1s/^HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p' || true
}

has_asset() {
  printf '%s\n' "$1" | grep -Fxq -- "$2"
}

download_state_asset() {
  local name="$1"
  rm -f "$STATE_FILE"
  timeout 90 gh release download "$RELEASE_TAG" -R "${GITHUB_REPOSITORY:?}" \
    -p "$name" -O "$STATE_FILE" >/dev/null 2>&1
}

restore_state() {
  if [ "${FRESH_STATE:-0}" = "1" ]; then
    log "FRESH_STATE=1：跳过状态恢复，空库启动"
    return 0
  fi

  local status
  status=$(release_status)
  case "$status" in
    200) ;;
    404)
      log "Release ${RELEASE_TAG} 不存在，按首启空库处理"
      return 0
      ;;
    *)
      die "无法确认状态 release（HTTP ${status:-unknown}），拒绝空库启动"
      ;;
  esac

  local assets
  assets=$(timeout 30 gh api "repos/${GITHUB_REPOSITORY:?}/releases/tags/${RELEASE_TAG}" \
    --jq '.assets[]?.name' 2>/dev/null) || die "读取 release 资产列表失败"

  local asset=""
  if has_asset "$assets" "$STATE_ASSET"; then
    asset="$STATE_ASSET"
  elif has_asset "$assets" "$STATE_PREV_ASSET"; then
    asset="$STATE_PREV_ASSET"
    log "::warning::${STATE_ASSET} 缺失（404），回退使用 ${STATE_PREV_ASSET}"
  else
    log "release 存在但 ${STATE_ASSET}/${STATE_PREV_ASSET} 均不存在（404），按首启空库处理"
    return 0
  fi

  if ! download_state_asset "$asset"; then
    die "状态快照 ${asset} 下载失败（release 存在）"
  fi

  local size
  size=$(stat -c%s "$STATE_FILE" 2>/dev/null || echo 0)
  if [ "$size" -le 0 ]; then
    die "状态快照 ${asset} 为空，拒绝空库启动"
  fi

  if ! timeout 180 "$BIN/zen-console-linux-amd64" -config "$ROOT/config.json" \
    -import-state "$STATE_FILE" >>"$PANEL_LOG" 2>&1; then
    die "状态导入失败（${asset}，${size} bytes）"
  fi
  log "状态已恢复并导入：${asset}（${size} bytes）"
}

start_panel() {
  log "启动面板 127.0.0.1:$PORT"
  ZEN_ROLE=remote \
  ZEN_REQUIRE_PANEL_TOKEN=1 \
  EXPOSE_V1=1 \
    "$BIN/zen-console-linux-amd64" -addr "127.0.0.1:$PORT" -config "$ROOT/config.json" >>"$PANEL_LOG" 2>&1 &
  PANEL_PID=$!
}

wait_local() {
  local deadline=$((SECONDS + LOCAL_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if ! child_alive "$PANEL_PID"; then
      log "面板进程已退出"
      return 1
    fi
    [ "$(local_code)" = "200" ] && return 0
    sleep 2
  done
  log "本地健康检查超时（${LOCAL_TIMEOUT}s）"
  return 1
}

start_tunnel() {
  log "启动 cloudflared（命名隧道，回源 http://localhost:$PORT）"
  env -i PATH="$PATH" CF_TUNNEL_TOKEN="$CF_TUNNEL_TOKEN" \
    "$BIN/cloudflared" tunnel --no-autoupdate --loglevel info run \
    --token "$CF_TUNNEL_TOKEN" >>"$CF_LOG" 2>&1 &
  CF_PID=$!
}

wait_public() {
  [ -n "$PUBLIC_HOST" ] || { log "未配置 ZEN_PUBLIC_HOST，跳过公网自检"; return 0; }
  local deadline=$((SECONDS + PUBLIC_TIMEOUT))
  local code
  while [ "$SECONDS" -lt "$deadline" ]; do
    code=$(public_code)
    case "$code" in
      2??|3??) return 0 ;;
    esac
    sleep 2
  done
  log "公网健康检查超时（${PUBLIC_TIMEOUT}s，最后 HTTP ${code:-000}）"
  return 1
}

child_alive() {
  local state
  kill -0 "$1" 2>/dev/null || return 1
  state=$(ps -o stat= -p "$1" 2>/dev/null | tr -d '[:space:]')
  case "$state" in
    Z*) return 1 ;;
    *) return 0 ;;
  esac
}

stop_child() {
  local pid="${1:-}"
  local name="${2:-child}"
  local i
  [ -n "$pid" ] || return 0
  child_alive "$pid" || return 0
  log "停止 ${name}（pid ${pid}）"
  kill -TERM "$pid" 2>/dev/null || true
  for i in $(seq 1 20); do
    child_alive "$pid" || return 0
    sleep 0.25
  done
  log "::warning::${name} 5s 内未退出，发送 SIGKILL"
  kill -KILL "$pid" 2>/dev/null || true
  for i in $(seq 1 10); do
    child_alive "$pid" || return 0
    sleep 0.1
  done
  log "::warning::${name} 仍未退出（pid ${pid}）"
  return 0
}

backup_prev() {
  local prev="$RUN/prev/${STATE_PREV_ASSET}"
  local size
  rm -f "$prev"
  if ! timeout 90 gh release download "$RELEASE_TAG" -R "${GITHUB_REPOSITORY:?}" \
    -p "$STATE_ASSET" -O "$prev" >/dev/null 2>&1; then
    log "::warning::未能下载当前 ${STATE_ASSET}，跳过上一版备份"
    return 1
  fi
  size=$(stat -c%s "$prev" 2>/dev/null || echo 0)
  if [ "$size" -le 0 ]; then
    log "::warning::当前 ${STATE_ASSET} 为空，跳过上一版备份"
    return 1
  fi
  if ! timeout 120 gh release upload "$RELEASE_TAG" "$prev" -R "${GITHUB_REPOSITORY:?}" \
    --clobber >/dev/null 2>&1; then
    log "::warning::上一版快照上传失败"
    return 1
  fi
  log "已备份上一版快照：${STATE_PREV_ASSET}（${size} bytes）"
}

checkpoint() {
  local tmp="$RUN/state.new"
  local up="$RUN/upload/state.bin"
  local code rc size
  rm -f "$tmp"
  mkdir -p "$RUN/upload"

  code=$(curl -fsS --max-time 30 --noproxy '*' -X POST \
    -H "Authorization: Bearer ${PANEL_TOKEN}" \
    -o "$tmp" -w '%{http_code}' \
    "$PANEL/api/admin/snapshot" 2>>"$PANEL_LOG")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    log "::warning::快照接口请求失败（curl=${rc}，HTTP ${code:-000}；空库时为 409）"
    rm -f "$tmp"
    return 1
  fi
  if [ "$code" != "200" ]; then
    log "::warning::快照接口返回 HTTP ${code}，跳过上传"
    rm -f "$tmp"
    return 1
  fi

  size=$(stat -c%s "$tmp" 2>/dev/null || echo 0)
  if [ "$size" -le 100 ]; then
    log "::warning::快照只有 ${size} bytes（<=100），跳过上传"
    rm -f "$tmp"
    return 1
  fi

  if ! cp "$tmp" "$up"; then
    log "::warning::快照暂存失败，跳过上传"
    return 1
  fi

  if timeout 30 gh release view "$RELEASE_TAG" -R "${GITHUB_REPOSITORY:?}" >/dev/null 2>&1; then
    backup_prev || true
    if ! timeout 120 gh release upload "$RELEASE_TAG" "$up" -R "${GITHUB_REPOSITORY:?}" \
      --clobber >/dev/null 2>&1; then
      log "::warning::快照上传失败"
      return 1
    fi
  else
    if ! timeout 120 gh release create "$RELEASE_TAG" -R "${GITHUB_REPOSITORY:?}" \
      --prerelease --title "panel state" \
      --notes "encrypted panel state (auto-generated)" "$up" >/dev/null 2>&1; then
      log "::warning::快照发布失败"
      return 1
    fi
  fi

  date -u +%FT%TZ >"$RUN/checkpoint.txt"
  log "快照已上传：${size} bytes"
}

final_snapshot() {
  [ "$FINAL_SNAPSHOT_DONE" = "1" ] && return 0
  FINAL_SNAPSHOT_DONE=1
  [ "$PANEL_READY" = "1" ] || return 0
  checkpoint || log "::warning::最终快照失败"
}

dispatch_next() {
  if [ "${ZEN_NO_HANDOFF:-0}" = "1" ]; then
    log "ZEN_NO_HANDOFF=1：不交班"
    return 0
  fi
  if [ "${DISPATCH_NEXT:-1}" != "1" ]; then
    log "DISPATCH_NEXT=0：本班结束后不交班"
    return 0
  fi

  local ref="${GITHUB_REF_NAME:-main}"
  case "$ref" in
    ''|*[!A-Za-z0-9._/-]*) ref="main" ;;
  esac
  local payload code rc attempt
  payload=$(printf '{"ref":"%s","inputs":{"max_run_sec":"%s","fresh_state":"0"}}' "$ref" "$TTL")

  for attempt in 1 2 3 4; do
    code=$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -X POST \
      -H "Authorization: Bearer ${GH_TOKEN:?}" \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      "https://api.github.com/repos/${GITHUB_REPOSITORY:?}/actions/workflows/panel.yml/dispatches" \
      -d "$payload" 2>/dev/null)
    rc=$?
    [ "$rc" -eq 0 ] || code=000
    if [ "$code" = "204" ]; then
      date -u +%FT%TZ >"$RUN/dispatched"
      log "交班 dispatch 成功（第 ${attempt} 次，HTTP 204）"
      return 0
    fi
    log "::warning::交班 dispatch 失败（第 ${attempt}/4 次，HTTP ${code:-000}）"
    [ "$attempt" -lt 4 ] && sleep $((attempt * 5))
  done
  log "::warning::交班未派出，等待兜底步骤或 cron"
  return 1
}

record_panel_restart() {
  local cutoff=$((SECONDS - RESTART_WINDOW))
  local ts
  local kept=()
  panel_restarts+=("$SECONDS")
  for ts in "${panel_restarts[@]}"; do
    [ "$ts" -ge "$cutoff" ] && kept+=("$ts")
  done
  panel_restarts=("${kept[@]}")
  panel_restart_total=$((panel_restart_total + 1))
}

cleanup() {
  local status=$?
  trap - EXIT TERM INT
  log "退出清理（status=${status}）"
  final_snapshot
  if [ "$PANEL_READY" = "1" ] && [ ! -f "$RUN/dispatched" ] && [ ! -f "$RUN/no-handoff" ]; then
    dispatch_next || true
  fi
  stop_child "$CF_PID" "cloudflared"
  stop_child "$PANEL_PID" "panel"
  printf '%s\n' "$SECONDS" >"$RUN/uptime.txt"
  printf 'panel_restarts=%s cf_restarts=0\n' "$panel_restart_total" >"$RUN/restarts.txt"
  log "本班结束"
}
trap cleanup EXIT
trap 'log "收到 SIGTERM，准备退出"; exit 143' TERM
trap 'log "收到 SIGINT，准备退出"; exit 130' INT

restore_state

start_panel
if ! wait_local; then
  start_rc=0
  if child_alive "$PANEL_PID"; then
    stop_child "$PANEL_PID" "panel"
    start_rc=124
  else
    wait "$PANEL_PID" 2>/dev/null
    start_rc=$?
  fi
  PANEL_PID=""
  last_line=$(tail -n 1 "$PANEL_LOG" 2>/dev/null | tr -d '\r' | sanitize | cut -c1-300)
  die "面板启动失败（退出码 ${start_rc}）${last_line:+；最后一行：$last_line}"
fi
PANEL_READY=1
log "面板本地健康检查通过"
date -u +%FT%TZ >"$RUN/started-at.txt"

start_tunnel
if [ -n "$PUBLIC_HOST" ]; then
  if wait_public; then
    log "公网已通（2xx/3xx）"
  else
    log "::warning::公网自检未通过，继续运行并等待交班"
  fi
  printf 'https://%s\n' "$PUBLIC_HOST" >"$RUN/public-url.txt"
fi

checkpoint || log "::warning::首次快照失败（会重试）"

next_local=$((SECONDS + 30))
next_public=$((SECONDS + 60))
next_snap=$((SECONDS + SNAPSHOT_INTERVAL))
local_fails=0
public_fails=0

while :; do
  sleep 10
  now=$SECONDS
  remain=$((TTL - now))

  if [ "$remain" -le 120 ]; then
    log "到达交班点（剩余 ${remain}s）"
    final_snapshot
    dispatch_next || true
    break
  fi

  if [ "$now" -ge "$next_local" ]; then
    next_local=$((now + 30))
    code=$(local_code)
    if [ "$code" = "200" ]; then
      local_fails=0
    else
      local_fails=$((local_fails + 1))
      log "::warning::本地健康检查失败（${local_fails}/3，HTTP ${code:-000}）"
      if [ "$local_fails" -ge 3 ]; then
        local_fails=0
        stop_child "$PANEL_PID" "panel"
        PANEL_PID=""
        record_panel_restart
        if [ "${#panel_restarts[@]}" -ge "$RESTART_LIMIT" ]; then
          log "::error::面板在 ${RESTART_WINDOW}s 内重启 ${#panel_restarts[@]} 次，尝试交班后退出"
          final_snapshot
          dispatch_next || true
          exit 1
        fi
        start_panel
        if wait_local; then
          log "面板已重启（窗口内第 ${#panel_restarts[@]} 次）"
        else
          log "::warning::重启后面板仍未就绪"
        fi
        next_local=$((SECONDS + 30))
      fi
    fi
  fi

  if [ -n "$PUBLIC_HOST" ] && [ "$now" -ge "$next_public" ]; then
    next_public=$((now + 60))
    code=$(public_code)
    case "$code" in
      2??|3??)
        public_fails=0
        ;;
      *)
        public_fails=$((public_fails + 1))
        log "::warning::公网健康检查失败（${public_fails} 次，HTTP ${code:-000}），继续运行"
        ;;
    esac
  fi

  if [ "$now" -ge "$next_snap" ]; then
    next_snap=$((now + SNAPSHOT_INTERVAL))
    checkpoint || log "::warning::周期快照失败"
  fi
done

log "本班结束"
