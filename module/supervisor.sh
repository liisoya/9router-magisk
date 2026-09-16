#!/system/bin/sh
# 9Router 守护进程：开机后拉起服务 + 崩溃自动重启 + 健康检查 + 日志轮转
# 由 service.sh 以后台方式拉起，本脚本持续运行。
MODDIR=${0%/*}
DATA=/data/adb/9router
LOGMAX=$((512 * 1024))

LOG=$DATA/log/service.log
PIDFILE=$DATA/9router.pid
PANEL_PIDFILE=$DATA/panel.pid

# 数据目录兜底：用户手动 `rm -rf /data/adb/9router` 后仍能自愈
mkdir -p "$DATA/log" "$DATA/tmp" "$DATA/data" 2>/dev/null
# 健康检查依赖 curl；个别 ROM 没有 curl，此时退化为"只看进程存活"，避免误判反复重启
HAVE_CURL=$(command -v curl 2>/dev/null)

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
  # 自愈：旧版安装脚本写的是绝对软链，内容换入正式目录后会悬空
  if [ ! -f "$APP/custom-server.js" ]; then
    _VER=$(cat "$DATA/current-version" 2>/dev/null)
    if [ -n "$_VER" ] && [ -d "$MODDIR/versions/$_VER/app" ]; then
      ln -sfn "versions/$_VER/app" "$MODDIR/app"
      log "app 软链已修复 -> versions/$_VER/app"
    fi
  fi
  [ -f "$APP/custom-server.js" ] || { log "错误: 找不到应用产物 $APP"; return 1; }
  # 内存相关参数可用 env.sh 调整：
  #   MAX_OLD_SPACE      V8 老生代上限（默认 512）
  #   CORE_NODE_FLAGS    额外 V8 参数（默认 --max-semi-space-size=4，实测省 ~10MB；
  #                      追求极限可再加 --optimize-for-size，再省 ~9MB，代价是 GC 更积极）
  [ -n "${CORE_NODE_FLAGS:-}" ] || CORE_NODE_FLAGS=--max-semi-space-size=4
  ( cd "$APP" && exec "$NODE" --dns-result-order=ipv4first \
      --max-old-space-size=${MAX_OLD_SPACE:-512} $CORE_NODE_FLAGS custom-server.js ) >> "$LOG" 2>&1 &
  CORE_PID=$!
  echo "$CORE_PID" > "$PIDFILE"
  echo -700 > "/proc/$CORE_PID/oom_score_adj" 2>/dev/null
  log "核心服务已启动 PID=$CORE_PID PORT=${APP_PORT:-20128} HOST=${BIND_HOST:-0.0.0.0}"
  return 0
}

start_panel() {
  # 必须先读配置再判断：否则 PANEL 被改成 0 之后，本进程内存里仍是旧值，
  # 面板会被反复拉起来（`9router ui off` 失效）。
  # 实测：面板 RSS 主要由 Node 基线决定（~47MB），V8 参数优化无收益，
  # 在意内存请在不需要时直接 `9router ui off` 关掉它。
  . "$DATA/env.sh"
  [ "${PANEL:-1}" = "1" ] || return 0
  export LD_LIBRARY_PATH=$MODDIR/runtime/lib
  NODE=$MODDIR/runtime/bin/node.bin
  ( exec "$NODE" --max-old-space-size=${PANEL_MAX_OLD_SPACE:-32} --dns-result-order=ipv4first \
      "$MODDIR/control-center.cjs" ) >> "$LOG" 2>&1 &
  echo $! > "$PANEL_PIDFILE"
  log "控制面板已启动 PID=$! PORT=${UI_PORT:-20129}"
}

stop_core() { kill $(cat "$PIDFILE" 2>/dev/null) 2>/dev/null; rm -f "$PIDFILE"; }
stop_panel() { kill $(cat "$PANEL_PIDFILE" 2>/dev/null) 2>/dev/null; rm -f "$PANEL_PIDFILE"; }

# 探针：输出 HTTP 状态码，超时/连接失败输出空
probe() { # $1=path $2=timeout(s) $3=Bearer key(可选)
  if [ -n "${3:-}" ]; then
    curl -s -m "$2" -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $3" \
      "http://127.0.0.1:${APP_PORT:-20128}$1" 2>/dev/null
  else
    curl -s -m "$2" -o /dev/null -w "%{http_code}" \
      "http://127.0.0.1:${APP_PORT:-20128}$1" 2>/dev/null
  fi
}

# 存活探测（每轮，必须廉价）：
# 只要求"能响应 HTTP 且不是 5xx"。不要用 /v1/models——它要枚举全部 provider，
# 在手机上实测 10s+，用 5s 超时探测会把健康进程误判成故障并反复重启。
health_alive() {
  [ -n "$HAVE_CURL" ] || return 0
  . "$DATA/env.sh"
  code=$(probe /favicon.svg 5)
  [ -n "$code" ] || code=$(probe /next.svg 5)
  case "$code" in
    2*|3*|4*) return 0 ;;
    *) return 1 ;;
  esac
}

# 功能探测（低频）：真打 API，容忍慢（手机上 ~10s）
health_api() {
  [ -n "$HAVE_CURL" ] || return 0
  . "$DATA/env.sh"
  if [ "${REQUIRE_API_KEY:-false}" = "true" ] && [ -n "${API_KEY:-}" ]; then
    code=$(probe /v1/models 25 "$API_KEY")
  else
    code=$(probe /v1/models 25)
  fi
  [ "$code" = "200" ] || [ "$code" = "307" ]
}

health_restart() {
  stop_panel; stop_core; sleep 2
  start_core && { CORE_PID=$(cat "$PIDFILE" 2>/dev/null); SINCE=$(date +%s); start_panel; }
}

wait_boot
# 探针必须单独带 LD_LIBRARY_PATH：否则动态链接器会报
# "CANNOT LINK EXECUTABLE ... libcares.so not found"（只是噪音，不影响运行）。
# 注意不要全局 export，避免系统 curl/toybox 误加载本模块的 .so。
NODE_VER=$(LD_LIBRARY_PATH=$MODDIR/runtime/lib "$MODDIR/runtime/bin/node.bin" -v 2>/dev/null)
log "守护进程就绪 (node=${NODE_VER:-未知}, curl=${HAVE_CURL:-无})"

FAILURES=0
SINCE=$(date +%s)
STOPPED=0
HEALTH_FAILS=0

# 读一次配置：HEALTH_INTERVAL 可调大以减少唤醒/探测开销
. "$DATA/env.sh"
HEALTH_EVERY=$(( ${HEALTH_INTERVAL:-60} / 5 )); [ "$HEALTH_EVERY" -ge 1 ] || HEALTH_EVERY=1
ROTATE_EVERY=$(( 300 / 5 ))   # 日志大小每 5 分钟看一次（见下：避免每 5s fork 一个 wc）

start_core || true
CORE_PID=$(cat "$PIDFILE" 2>/dev/null)
start_panel

TICKS=0
while true; do
  sleep 5
  TICKS=$((TICKS + 1))

  # 面板挂了直接补起来（它很轻，不做退避）；PANEL=0 时 start_panel 内部直接返回
  [ "${STOPPED:-0}" = "1" ] || { [ -f "$PANEL_PIDFILE" ] || start_panel; }

  # 核心服务存活检查（kill -0 是内建，不产生子进程）
  if [ "${STOPPED:-0}" != "1" ] && { [ -z "${CORE_PID:-}" ] || ! kill -0 "$CORE_PID" 2>/dev/null; }; then
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
    start_core && { CORE_PID=$(cat "$PIDFILE" 2>/dev/null); SINCE=$(date +%s); start_panel; }
    continue
  fi

  # 控制面板 / CLI 发来的白名单操作
  if [ -f "$DATA/control-request" ]; then
    REQ=$(cat "$DATA/control-request" 2>/dev/null)
    rm -f "$DATA/control-request"
    log "收到操作请求: $REQ"
    case "$REQ" in
      start)   STOPPED=0; [ -f "$PIDFILE" ] || start_core ;;
      stop)    STOPPED=1; stop_panel; stop_core ;;
      restart) STOPPED=0; stop_panel; stop_core; sleep 2; start_core; start_panel ;;
      lan-on)  sed -i 's/^BIND_HOST=.*/BIND_HOST=0.0.0.0/' "$DATA/env.sh"; stop_core; sleep 2; start_core ;;
      lan-off) sed -i 's/^BIND_HOST=.*/BIND_HOST=127.0.0.1/' "$DATA/env.sh"; stop_core; sleep 2; start_core ;;
      panel-on)  sed -i 's/^PANEL=.*/PANEL=1/' "$DATA/env.sh"; PANEL=1; STOPPED=0; start_panel ;;
      panel-off) sed -i 's/^PANEL=.*/PANEL=0/' "$DATA/env.sh"; PANEL=0; stop_panel ;;
    esac
    CORE_PID=$(cat "$PIDFILE" 2>/dev/null)
    SINCE=$(date +%s); FAILURES=0
    continue
  fi

  # 日志轮转：低频执行，避免每 5s fork 一次 wc -c（一天可省约 1.7 万次）
  [ $((TICKS % ROTATE_EVERY)) -eq 0 ] && rotate

  # 健康检查（默认每 60s，可由 env.sh 的 HEALTH_INTERVAL 调整）
  #   存活探测：每轮，廉价（静态资源）；连续 3 次失败才重启，避免误杀
  #   功能探测：每 5 个健康周期（约 5 分钟）打一次 /v1/models，失败仅告警
  if [ "${STOPPED:-0}" != "1" ] && [ $((TICKS % HEALTH_EVERY)) -eq 0 ]; then
    if health_alive; then
      HEALTH_FAILS=0
    else
      HEALTH_FAILS=$((HEALTH_FAILS + 1))
      log "存活探测失败 ${HEALTH_FAILS}/3（code=${code:-超时}）"
      if [ "$HEALTH_FAILS" -ge 3 ]; then
        log "连续 3 次存活探测失败，重启服务"
        health_restart
        HEALTH_FAILS=0
      fi
    fi
    if [ $((TICKS % (HEALTH_EVERY * 5))) -eq 0 ]; then
      if health_api; then
        log "API 探测正常（code=$code）"
      else
        log "API 探测异常（code=${code:-超时}）：/v1/models 较慢时属正常，仅告警不重启"
      fi
    fi
  fi
done
