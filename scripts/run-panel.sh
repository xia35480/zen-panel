#!/usr/bin/env bash
# 在 GitHub Actions runner 上跑 zen-console：
#   恢复密文状态 → 起面板 → 起 Cloudflare 命名隧道 → 守护 → 周期快照 → 到点交班。
# 关键约束：
#   * 同一个 concurrency group 里只允许一个实例（同名隧道双连接会被 CF 轮询，表现为随机 502）。
#   * 公有库的 release 资产是公开的，所以 state 必须密文（PANEL_STATE_KEY）。
#   * 任何会打印 token 的动作都不做；需要打印时先 ::add-mask::。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin"
RUN="$ROOT/run"
STATE_DIR="$ROOT/state"
mkdir -p "$RUN" "$STATE_DIR"

PORT="${PANEL_PORT:-8081}"
TTL="${MAX_RUN_SEC:-18000}"
PUBLIC_HOST="${ZEN_PUBLIC_HOST:-}"
# 公开仓库的 job 日志是所有人可见的。域名本身能通过 DNS/证书透明日志查到，
# 但没必要主动写在日志里被人顺手扫到；统一打码，后续出现的地方都会变成 ***。
[ -n "$PUBLIC_HOST" ] && echo "::add-mask::$PUBLIC_HOST"
RELEASE_TAG="${STATE_RELEASE:-panel-state}"
STATE_ASSET="${STATE_ASSET:-state.bin}"
STATE_FILE="$STATE_DIR/$STATE_ASSET"
PANEL_LOG="$RUN/panel.log"
CF_LOG="$RUN/cloudflared.log"
PANEL="http://127.0.0.1:$PORT"

PANEL_PID=""
CF_PID=""

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { log "::error::$*"; printf '%s\n' "$*" >"$RUN/no-handoff"; exit 1; }

for v in CF_TUNNEL_TOKEN PANEL_TOKEN ZEN_API_KEY ZEN_ACCOUNTS_JSON; do
  [ -n "${!v:-}" ] || die "缺少必需 secret/env: $v"
done
[ -n "${PANEL_STATE_KEY:-}" ] || die "缺少必需 secret/env: PANEL_STATE_KEY"

local_code() {
  curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 3 "$PANEL/api/healthz" 2>/dev/null || true
}
public_code() {
  [ -n "$PUBLIC_HOST" ] || return 1
  curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 10 "https://$PUBLIC_HOST/api/healthz" 2>/dev/null || true
}

restore_state() {
  if [ "${FRESH_STATE:-0}" = "1" ]; then
    log "FRESH_STATE=1：跳过状态恢复，空库启动"
    return 0
  fi
  rm -f "$STATE_FILE"
  if gh release download "$RELEASE_TAG" -R "${GITHUB_REPOSITORY:?}" -p "$STATE_ASSET" -O "$STATE_FILE" >/dev/null 2>&1; then
    log "状态已恢复：$(stat -c%s "$STATE_FILE") bytes"
  else
    log "没有历史状态快照，空库启动"
  fi
}

start_panel() {
  log "启动面板 127.0.0.1:$PORT（状态文件 $STATE_FILE）"
  ZEN_STATE_IMPORT="$STATE_FILE" \
  ZEN_ROLE=remote \
  ZEN_REQUIRE_PANEL_TOKEN=1 \
  EXPOSE_V1=1 \
    "$BIN/zen-console-linux-amd64" -addr "127.0.0.1:$PORT" -config "$ROOT/config.json" >>"$PANEL_LOG" 2>&1 &
  PANEL_PID=$!
}

wait_local() {
  for _ in $(seq 1 120); do
    [ "$(local_code)" = "200" ] && return 0
    sleep 1
  done
  return 1
}

start_tunnel() {
  log "启动 cloudflared（命名隧道，回源 http://localhost:$PORT）"
  "$BIN/cloudflared" tunnel --no-autoupdate --loglevel info run --token "$CF_TUNNEL_TOKEN" >>"$CF_LOG" 2>&1 &
  CF_PID=$!
}

wait_public() {
  [ -n "$PUBLIC_HOST" ] || return 0
  for _ in $(seq 1 90); do
    [ "$(public_code)" = "200" ] && return 0
    sleep 1
  done
  return 1
}

checkpoint() {
  local tmp="$STATE_DIR/$STATE_ASSET"
  if ! "$BIN/zen-console-linux-amd64" -config "$ROOT/config.json" -export-state "$tmp" >>"$PANEL_LOG" 2>&1; then
    log "快照导出失败"
    return 1
  fi
  if gh release view "$RELEASE_TAG" -R "${GITHUB_REPOSITORY:?}" >/dev/null 2>&1; then
    gh release upload "$RELEASE_TAG" "$tmp" -R "${GITHUB_REPOSITORY:?}" --clobber >/dev/null 2>&1 || { log "快照上传失败"; return 1; }
  else
    gh release create "$RELEASE_TAG" -R "${GITHUB_REPOSITORY:?}" --prerelease \
      --title "panel state" --notes "encrypted panel state (auto-generated)" "$tmp" >/dev/null 2>&1 \
      || { log "快照发布失败"; return 1; }
  fi
  date -u +%FT%TZ >"$RUN/checkpoint.txt"
  log "快照已上传：$(stat -c%s "$tmp") bytes"
}

dispatch_next() {
  if [ "${DISPATCH_NEXT:-1}" != "1" ]; then
    log "DISPATCH_NEXT=0：本班结束后不交班"
    return 0
  fi
  local ref="${GITHUB_REF_NAME:-main}"
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer ${GH_TOKEN:?}" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/${GITHUB_REPOSITORY:?}/actions/workflows/panel.yml/dispatches" \
    -d "{\"ref\":\"$ref\",\"inputs\":{\"max_run_sec\":\"$TTL\",\"fresh_state\":\"0\"}}")
  log "交班 dispatch → HTTP $code"
  if [ "$code" != "204" ]; then
    log "::warning::交班没派出去（HTTP $code），等 cron 或手动拉起"
  fi
}

cleanup() {
  log "退出清理"
  [ -n "$CF_PID" ] && kill "$CF_PID" 2>/dev/null
  [ -n "$PANEL_PID" ] && kill "$PANEL_PID" 2>/dev/null
  wait 2>/dev/null
  true
}
trap cleanup EXIT

restore_state

start_panel
if ! wait_local; then
  tail -n 60 "$PANEL_LOG" 2>/dev/null
  die "面板 120s 内没有就绪"
fi
log "面板本地健康检查通过"
date -u +%FT%TZ >"$RUN/started-at.txt"

start_tunnel
if wait_public; then
  log "公网已通：https://$PUBLIC_HOST"
else
  log "::warning::公网自检未通过（隧道可能仍在注册或有 Access 策略）"
fi
[ -n "$PUBLIC_HOST" ] && printf 'https://%s\n' "$PUBLIC_HOST" >"$RUN/public-url.txt"

checkpoint || log "::warning::首次快照失败（会重试）"

next_local=$((SECONDS + 30))
next_public=$((SECONDS + 60))
next_snap=$((SECONDS + 300))
panel_restarts=0
cf_restarts=0
local_fails=0
public_fails=0

while :; do
  sleep 10
  now=$SECONDS
  remain=$((TTL - now))

  if [ "$remain" -le 120 ]; then
    log "到达交班点（剩余 ${remain}s）"
    checkpoint || log "::warning::最终快照失败"
    dispatch_next
    break
  fi

  if [ "$now" -ge "$next_local" ]; then
    next_local=$((now + 30))
    if [ "$(local_code)" = "200" ]; then
      local_fails=0
    else
      local_fails=$((local_fails + 1))
      log "本地健康检查失败（$local_fails/3）"
      if [ "$local_fails" -ge 3 ]; then
        local_fails=0
        kill "$PANEL_PID" 2>/dev/null
        wait "$PANEL_PID" 2>/dev/null
        panel_restarts=$((panel_restarts + 1))
        [ "$panel_restarts" -gt 5 ] && die "面板反复退出（$panel_restarts 次）"
        start_panel
        wait_local || log "::warning::重启后面板仍未就绪"
      fi
    fi
  fi

  if [ -n "$PUBLIC_HOST" ] && [ "$now" -ge "$next_public" ]; then
    next_public=$((now + 60))
    if [ "$(public_code)" = "200" ]; then
      public_fails=0
    else
      public_fails=$((public_fails + 1))
      log "公网健康检查失败（$public_fails/3）"
      if [ "$public_fails" -ge 3 ]; then
        public_fails=0
        kill "$CF_PID" 2>/dev/null
        wait "$CF_PID" 2>/dev/null
        cf_restarts=$((cf_restarts + 1))
        [ "$cf_restarts" -gt 5 ] && die "cloudflared 反复退出（$cf_restarts 次）"
        start_tunnel
        wait_public || log "::warning::隧道重启后公网仍未通"
      fi
    fi
  fi

  if [ "$now" -ge "$next_snap" ]; then
    next_snap=$((now + 300))
    checkpoint || log "::warning::周期快照失败"
  fi
done

printf '%s\n' "$SECONDS" >"$RUN/uptime.txt"
printf 'panel_restarts=%s cf_restarts=%s\n' "$panel_restarts" "$cf_restarts" >"$RUN/restarts.txt"
log "本班结束"
