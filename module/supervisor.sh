#!/system/bin/sh
# 9Router 守护进程：开机后拉起服务 + 崩溃自动重启 + 健康检查 + 日志轮转
# 由 service.sh 以后台方式拉起，本脚本持续运行。
MODDIR=${0%/*}
DATA=/data/adb/9router
LOGMAX=$((512 * 1024))

LOG=$DATA/log/service.log
PIDFILE=$DATA/9router.pid
PANEL_PIDFILE=$DATA/panel.pid

mkdir -p "$DATA/log" 2>/dev/null

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

rotate() {
  sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  if [ "$sz" -gt "$LOGMAX" ]; then
    mv "$LOG" "$LOG.old" 2>/dev/null
    : > "$LOG"
  fi
}

wait_boot() {
  while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do sleep 3; done
  sleep 2
}

orb_used() { # $1=port -> 非空表示已被占用
  toybox ss -tln 2>/dev/null | grep -q ":$1 " && echo yes
  return 0
}

start_core() {
  . "$DATA/env.sh"
  export HOME=$DATA TMPDIR=$DATA/tmp DATA_DIR=$DATA/data \
    NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 \
    LD_LIBRARY_PATH=$MODDIR/runtime/lib \
    SSL_CERT_FILE=$MODDIR/runtime/lib/cacert.pem \
    OPENSSL_CONF=$MODDIR/runtime/lib/openssl.cnf \
    PORT=${APP_PORT:-20128} HOSTNAME=${BIND_HOST:-0.0.0.0} \
    UV_THREADPOOL_SIZE=${UV_THREADPOOL_SIZE:-2} \
    JWT_SECRET INITIAL_PASSWORD REQUIRE_API_KEY
  NODE=$MODDIR/runtime/bin/node.bin
  APP=$MODDIR/app
  [ -x "$NODE" ] || { log "错误: 找不到 node 运行时"; return 1; }
  [ -f "$APP/custom-server.js" ] || { log "错误: 找不到应用产物 $APP"; return 1; }
  ( cd "$APP" && exec "$NODE" --dns-result-order=ipv4first \
      --max-old-space-size=${MAX_OLD_SPACE:-512} custom-server.js ) >> "$LOG" 2>&1 &
  CORE_PID=$!
  echo "$CORE_PID" > "$PIDFILE"
  echo -700 > "/proc/$CORE_PID/oom_score_adj" 2>/dev/null
  log "核心服务已启动 PID=$CORE_PID PORT=${APP_PORT:-20128} HOST=${BIND_HOST:-0.0.0.0}"
  return 0
}

start_panel() {
  [ "${PANEL:-1}" = "1" ] || return 0
  . "$DATA/env.sh"
  export LD_LIBRARY_PATH=$MODDIR/runtime/lib
  NODE=$MODDIR/runtime/bin/node.bin
  ( exec "$NODE" --max-old-space-size=32 --dns-result-order=ipv4first \
      "$MODDIR/control-center.cjs" ) >> "$LOG" 2>&1 &
  echo $! > "$PANEL_PIDFILE"
  log "控制面板已启动 PID=$! PORT=${UI_PORT:-20129}"
}

stop_core() { kill $(cat "$PIDFILE" 2>/dev/null) 2>/dev/null; rm -f "$PIDFILE"; }
stop_panel() { kill $(cat "$PANEL_PIDFILE" 2>/dev/null) 2>/dev/null; rm -f "$PANEL_PIDFILE"; }

health() {
  . "$DATA/env.sh"
  url="http://127.0.0.1:${APP_PORT:-20128}/v1/models"
  if [ "${REQUIRE_API_KEY:-false}" = "true" ] && [ -n "${API_KEY:-}" ]; then
    code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $API_KEY" "$url" 2>/dev/null)
  else
    code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
  fi
  [ "$code" = "200" ] || [ "$code" = "307" ]
}

wait_boot
log "守护进程就绪 (node=$( $MODDIR/runtime/bin/node.bin -v 2>/dev/null ))"

FAILURES=0
SINCE=$(date +%s)
LASTCHECK=$SINCE
start_core || true
CORE_PID=$(cat "$PIDFILE" 2>/dev/null)
start_panel

while true; do
  sleep 5
  rotate

  # 面板挂了直接补起来（它很轻，不做退避）
  if [ "${PANEL:-1}" = "1" ] && [ ! -f "$PANEL_PIDFILE" ]; then start_panel; fi

  # 核心服务存活检查
  if [ -z "${CORE_PID:-}" ] || ! kill -0 "$CORE_PID" 2>/dev/null; then
    log "核心服务已退出"
    stop_panel
    UPTIME=$(( $(date +%s) - SINCE ))
    if [ "$UPTIME" -lt 30 ]; then FAILURES=$((FAILURES + 1)); else FAILURES=0; fi
    if [ "$FAILURES" -ge 5 ]; then
      DELAY=60
      log "连续快速崩溃 $FAILURES 次，暂停 ${DELAY}s 后再试（检查 $LOG）"
    else
      DELAY=$((FAILURES * 3))
    fi
    sleep "$DELAY"
    start_core && { CORE_PID=$(cat "$PIDFILE" 2>/dev/null); SINCE=$(date +%s); [ "${PANEL:-1}" = "1" ] && start_panel; }
    continue
  fi

  # 控制面板 / CLI 发来的白名单操作
  if [ -f "$DATA/control-request" ]; then
    REQ=$(cat "$DATA/control-request" 2>/dev/null)
    rm -f "$DATA/control-request"
    log "收到操作请求: $REQ"
    case "$REQ" in
      start)   [ -f "$PIDFILE" ] || start_core ;;
      stop)    stop_panel; stop_core ;;
      restart) stop_panel; stop_core; sleep 2; start_core; start_panel ;;
      lan-on)  sed -i 's/^BIND_HOST=.*/BIND_HOST=0.0.0.0/' "$DATA/env.sh"; stop_core; sleep 2; start_core ;;
      lan-off) sed -i 's/^BIND_HOST=.*/BIND_HOST=127.0.0.1/' "$DATA/env.sh"; stop_core; sleep 2; start_core ;;
      panel-on)  sed -i 's/^PANEL=.*/PANEL=1/' "$DATA/env.sh"; start_panel ;;
      panel-off) sed -i 's/^PANEL=.*/PANEL=0/' "$DATA/env.sh"; stop_panel ;;
    esac
    CORE_PID=$(cat "$PIDFILE" 2>/dev/null)
    SINCE=$(date +%s); FAILURES=0
    continue
  fi

  # 健康检查（每 60s 一次）
  NOW=$(date +%s)
  if [ $((NOW - LASTCHECK)) -ge 60 ]; then
    LASTCHECK=$NOW
    health || { log "健康检查失败，重启服务"; stop_panel; stop_core; sleep 2; start_core && CORE_PID=$(cat "$PIDFILE" 2>/dev/null); start_panel; }
  fi
done
