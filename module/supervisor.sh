#!/system/bin/sh
# 9Router 守护进程：开机后拉起服务 + 崩溃自动重启 + 健康检查 + 日志轮转
# 由 service.sh 以后台方式拉起，本脚本持续运行。
MODDIR=${0%/*}
DATA=/data/adb/9router
LOGMAX=$((512 * 1024))

LOG=$DATA/log/service.log
PIDFILE=$DATA/9router.pid
PANEL_PIDFILE=$DATA/panel.pid

# ── node 运行时（双份互为备份）──────────────────────────────────────────
#   $MODDIR/runtime   模块自带，随刷模块更新；但模块目录会被管理器"换入/镜像/清理"
#                     （部分 KernelSU 分支上出现过文件被抹掉），不能当成唯一来源
#   $DATA/runtime     数据区镜像，模块管理器不会碰它
# 开机时两份都做"存在 + 大小 + 真能跑出版本号"的校验，可用者优先；任何一份可用就能跑。
# 运行时不可用属于环境/文件问题（不是"崩溃"），走长退避，绝不刷日志刷到 512KB。
RT_MODULE=$MODDIR/runtime
RT_MIRROR=$DATA/runtime
NODE=                          # 解析出的 node 可执行文件
RTLIB=                         # 与之配套的 lib 目录（LD_LIBRARY_PATH）
NODE_VER=                      # 探针跑出来的版本号（v24.x.y）
NODE_FATAL=0                   # 1 = 当前没有任何可用的 node
FATAL_WAIT=300                 # 运行时不可用时的重试间隔（秒）

# 数据目录兜底：用户手动 `rm -rf /data/adb/9router` 后仍能自愈
mkdir -p "$DATA/log" "$DATA/tmp" "$DATA/data" 2>/dev/null
# 健康检查依赖 curl；个别 ROM 没有 curl，此时退化为"只看进程存活"，避免误判反复重启
HAVE_CURL=$(command -v curl 2>/dev/null)

log() {
  TS=$(date '+%F %T' 2>/dev/null)
  # date 不可用时留空会写成 "[]"，加个占位符以便一眼看出是环境异常
  [ -n "$TS" ] || TS="时间戳不可用"
  echo "[$TS] $*" >> "$LOG"
}

rotate() {
  sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  if [ "$sz" -gt "$LOGMAX" ]; then
    mv "$LOG" "$LOG.old" 2>/dev/null
    : > "$LOG"
  fi
}

size_of() { wc -c < "$1" 2>/dev/null | tr -d ' \n'; }

# 运行时探针：文件必须"真能跑出版本号"才算可用。
# 只判断 -x 会误判：文件存在但被截断/损坏、或系统的 ELF 解释器不可达时，
# exec 会以 ENOENT/EACCES 失败（日志里就表现为 "node.bin: No such file or directory"）。
node_probe() { # $1=node 路径 $2=lib 目录
  [ -x "$1" ] || return 1
  # 用 {} 包住：被截断的 ELF 会让子进程收到 SIGSEGV，shell 会额外打一行
  # "Segmentation fault"，这个由 shell 自己输出，靠子进程的 2>/dev/null 挡不住
  V=$( { LD_LIBRARY_PATH="$2" "$1" -v; } 2>/dev/null )
  case "$V" in
    v[0-9]*) echo "$V"; return 0 ;;
  esac
  return 1
}

# 逐文件复制运行时：不依赖 cp -a/-r（各 ROM 的 toybox 支持程度不一）
copy_runtime() { # $1=源 runtime 目录 $2=目标 runtime 目录
  [ -f "$1/bin/node.bin" ] || return 1
  mkdir -p "$2/bin" "$2/lib" 2>/dev/null || return 1
  cp "$1/bin/node.bin" "$2/bin/node.bin" 2>/dev/null || return 1
  chmod 0755 "$2/bin/node.bin" 2>/dev/null
  for f in "$1"/lib/*; do
    [ -f "$f" ] && cp "$f" "$2/lib/" 2>/dev/null
  done
  return 0
}

# 解析运行时（必要时自愈）：优先数据区镜像，其次模块自带，最后回退系统 node
resolve_runtime() {
  . "$DATA/env.sh" 2>/dev/null
  MVER=$(node_probe "$RT_MODULE/bin/node.bin" "$RT_MODULE/lib")
  VVER=$(node_probe "$RT_MIRROR/bin/node.bin" "$RT_MIRROR/lib")
  # 模块自带那份可用、且与镜像不一致（刚刷过模块）→ 以模块为源刷新镜像
  if [ -n "$MVER" ] && [ "${RUNTIME_MIRROR:-1}" = "1" ]; then
    if [ -z "$VVER" ]; then
      copy_runtime "$RT_MODULE" "$RT_MIRROR" && VVER=$MVER
    elif [ "$(size_of "$RT_MODULE/bin/node.bin")" != "$(size_of "$RT_MIRROR/bin/node.bin")" ]; then
      copy_runtime "$RT_MODULE" "$RT_MIRROR" && VVER=$MVER
    fi
  fi
  if [ -n "$VVER" ]; then
    NODE=$RT_MIRROR/bin/node.bin; RTLIB=$RT_MIRROR/lib; NODE_VER=$VVER; NODE_FATAL=0; return 0
  fi
  if [ -n "$MVER" ]; then
    NODE=$RT_MODULE/bin/node.bin; RTLIB=$RT_MODULE/lib; NODE_VER=$MVER; NODE_FATAL=0; return 0
  fi
  # 兜底：设备上现成的 node（Termux 等），此时不要指到我们的 lib
  SN=$(command -v node 2>/dev/null)
  if [ -n "$SN" ]; then
    SV=$("$SN" -v 2>/dev/null)
    case "$SV" in
      v[0-9]*)
        log "警告: 模块运行时不可用，暂用系统 node: $SN ($SV)"
        NODE=$SN; RTLIB=; NODE_VER=$SV; NODE_FATAL=0; return 0 ;;
    esac
  fi
  NODE=; RTLIB=; NODE_VER=; NODE_FATAL=1
  return 1
}

wait_boot() {
  while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do sleep 3; done
  sleep 2
}

# PID 文件里的进程是否真是我们的核心：重启后 PID 会被复用，
# 否则可能对着别人的进程 kill -0 成功 → 以为服务在跑（或误杀无关进程）
pid_is_core() { # $1=pid
  [ -n "$1" ] || return 1
  [ -r "/proc/$1/cmdline" ] || return 1
  CMDL=$(tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null)
  case "$CMDL" in
    *custom-server.js*) return 0 ;;
  esac
  return 1
}

start_core() {
  [ -n "$NODE" ] || return 1
  . "$DATA/env.sh"
  export HOME=$DATA TMPDIR=$DATA/tmp DATA_DIR=$DATA/data \
    NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 \
    PORT=${APP_PORT:-20128} HOSTNAME=${BIND_HOST:-0.0.0.0} \
    UV_THREADPOOL_SIZE=${UV_THREADPOOL_SIZE:-2} \
    JWT_SECRET INITIAL_PASSWORD REQUIRE_API_KEY
  if [ -n "$RTLIB" ]; then
    export LD_LIBRARY_PATH=$RTLIB SSL_CERT_FILE=$RTLIB/cacert.pem OPENSSL_CONF=$RTLIB/openssl.cnf
  fi
  APP=$MODDIR/app
  # 自愈：旧版安装脚本写的是绝对软链，内容换入正式目录后会悬空
  if [ ! -f "$APP/custom-server.js" ]; then
    _VER=$(cat "$DATA/current-version" 2>/dev/null)
    if [ -n "$_VER" ] && [ -d "$MODDIR/versions/$_VER/app" ]; then
      ln -sfn "versions/$_VER/app" "$MODDIR/app"
      log "app 软链已修复 -> versions/$_VER/app"
    fi
  fi
  if [ ! -f "$APP/custom-server.js" ]; then
    log "错误: 找不到应用产物 $APP/custom-server.js（可用 9router update 重新下载应用）"
    return 1
  fi
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
  # exec 失败（node 缺失/损坏/解释器不可达）时子进程会瞬间消失：这里确认一次，
  # 避免把"启动失败"记成"崩溃"，也避免打出自欺欺人的"已启动"日志
  sleep 1
  if ! kill -0 "$CORE_PID" 2>/dev/null; then
    rm -f "$PIDFILE"
    CORE_PID=
    log "核心服务启动失败：$NODE 无法执行或启动后立即退出（运行时缺失/损坏；上方为该进程的原始报错）"
    return 1
  fi
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
  [ -n "$NODE" ] || return 1
  [ -n "$RTLIB" ] && export LD_LIBRARY_PATH=$RTLIB
  ( exec "$NODE" --max-old-space-size=${PANEL_MAX_OLD_SPACE:-32} --dns-result-order=ipv4first \
      "$MODDIR/control-center.cjs" ) >> "$LOG" 2>&1 &
  PANEL_PID=$!
  echo "$PANEL_PID" > "$PANEL_PIDFILE"
  sleep 1
  if ! kill -0 "$PANEL_PID" 2>/dev/null; then
    rm -f "$PANEL_PIDFILE"
    log "控制面板启动失败：$NODE 无法执行（运行时缺失/损坏；上方为该进程的原始报错）"
    return 1
  fi
  log "控制面板已启动 PID=$PANEL_PID PORT=${UI_PORT:-20129}"
  return 0
}

stop_core() {
  P=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$P" ] && pid_is_core "$P" && kill "$P" 2>/dev/null
  rm -f "$PIDFILE"
}
stop_panel() {
  P=$(cat "$PANEL_PIDFILE" 2>/dev/null)
  [ -n "$P" ] && kill -0 "$P" 2>/dev/null && kill "$P" 2>/dev/null
  rm -f "$PANEL_PIDFILE"
}

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
  if start_core; then
    CORE_PID=$(cat "$PIDFILE" 2>/dev/null); SINCE=$(date +%s); start_panel
  fi
}

wait_boot

# ── 启动自检 ────────────────────────────────────────────────────────────
# 探针必须单独带 LD_LIBRARY_PATH：否则动态链接器会报
# "CANNOT LINK EXECUTABLE ... libcares.so not found"（只是噪音，不影响运行）。
# 注意不要全局 export，避免系统 curl/toybox 误加载本模块的 .so。
resolve_runtime || true

# 环境探针：把"模块文件缺失"和"系统工具/ELF 解释器不可用"分开记录，
# 用户下次贴日志就能直接定位（缺 date/getprop、linker64 不存在、/data 满 等）。
if [ -e /system/bin/linker64 ]; then LINKER=ok; else LINKER=缺失; fi
if [ -n "$(date +%s 2>/dev/null)" ]; then DATE_OK=ok; else DATE_OK=异常; fi
if command -v getprop >/dev/null 2>&1; then GETPROP=ok; else GETPROP=缺; fi
if [ -x "$RT_MODULE/bin/node.bin" ]; then RTM=在; else RTM=缺; fi
if [ -x "$RT_MIRROR/bin/node.bin" ]; then RTV=在; else RTV=缺; fi
DF_FREE=$(df -h /data 2>/dev/null | tail -n 1 | awk '{print $4}')

log "守护进程就绪 (node=${NODE_VER:-未知}, 使用=${NODE:-无})"
log "运行时自检: 模块自带=$RTM 数据区镜像=$RTV 大小=$(size_of "$RT_MODULE/bin/node.bin" 2>/dev/null)/$(size_of "$RT_MIRROR/bin/node.bin" 2>/dev/null)"
log "环境自检: linker64=$LINKER date=$DATE_OK getprop=$GETPROP curl=${HAVE_CURL:-无} /data剩余=${DF_FREE:-未知}"
[ -n "$NODE_VER" ] || log "警告: node 运行时当前不可用（详见上面的自检行）；请执行 9router doctor 查看原因"

FAILURES=0
SINCE=$(date +%s)
STOPPED=0
HEALTH_FAILS=0
PANEL_RETRY_AT=0

# 读一次配置：HEALTH_INTERVAL 可调大以减少唤醒/探测开销
. "$DATA/env.sh"
HEALTH_EVERY=$(( ${HEALTH_INTERVAL:-60} / 5 )); [ "$HEALTH_EVERY" -ge 1 ] || HEALTH_EVERY=1
ROTATE_EVERY=$(( 300 / 5 ))   # 日志大小每 5 分钟看一次（见下：避免每 5s fork 一个 wc）
RECHECK_EVERY=$(( 300 / 5 ))  # 每 5 分钟重新校验/自愈一次运行时（无需重启即可恢复）

# 陈旧 PID 文件（上次开机留下的、且 PID 可能已被复用）：丢掉，避免误判
CORE_PID=$(cat "$PIDFILE" 2>/dev/null)
if [ -n "$CORE_PID" ] && ! pid_is_core "$CORE_PID"; then
  rm -f "$PIDFILE"
  CORE_PID=
fi

start_core || true
CORE_PID=$(cat "$PIDFILE" 2>/dev/null)
pid_is_core "$CORE_PID" || CORE_PID=
start_panel

TICKS=0
while true; do
  sleep 5
  TICKS=$((TICKS + 1))

  # 面板挂了直接补起来（它很轻，不做退避）；PANEL=0 时 start_panel 内部直接返回。
  # 启动失败时 60s 内不再重试，避免每 5s 往日志里灌一条失败记录。
  if [ "${STOPPED:-0}" != "1" ] && [ ! -f "$PANEL_PIDFILE" ] && [ -n "$NODE" ] \
     && [ "$TICKS" -ge "$PANEL_RETRY_AT" ]; then
    start_panel || PANEL_RETRY_AT=$((TICKS + 12))
  fi

  # 核心服务存活检查（kill -0 是内建，不产生子进程）
  if [ "${STOPPED:-0}" != "1" ] && { [ -z "${CORE_PID:-}" ] || ! kill -0 "$CORE_PID" 2>/dev/null; }; then
    stop_panel
    # 运行时不可用：环境/文件问题，低频重试 + 明确提示，不按"崩溃"刷日志
    if [ "$NODE_FATAL" = "1" ]; then
      log "core 未运行：node 运行时不可用（$RT_MIRROR 与 $RT_MODULE 均无法执行）；${FATAL_WAIT}s 后重试，诊断: 9router doctor"
      sleep "$FATAL_WAIT"
      resolve_runtime || true
      continue
    fi
    UPTIME=$(( $(date +%s) - SINCE ))
    # 稳定运行过 2 分钟以上 → 退避归零；否则累加，最多 60s
    [ "$UPTIME" -ge 120 ] && FAILURES=0
    FAILURES=$((FAILURES + 1))
    if [ "$FAILURES" -ge 5 ]; then
      DELAY=60
      log "连续失败 $FAILURES 次，暂停 ${DELAY}s 后再试（诊断: 9router doctor；原始报错见 $LOG）"
    else
      DELAY=$((FAILURES * 5)); [ "$DELAY" -ge 5 ] || DELAY=5
    fi
    sleep "$DELAY"
    if start_core; then
      CORE_PID=$(cat "$PIDFILE" 2>/dev/null)
      SINCE=$(date +%s)
      start_panel
    fi
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
    SINCE=$(date +%s); FAILURES=0; PANEL_RETRY_AT=0
    continue
  fi

  # 日志轮转：低频执行，避免每 5s fork 一次 wc -c（一天可省约 1.7 万次）
  [ $((TICKS % ROTATE_EVERY)) -eq 0 ] && rotate

  # 运行时复查：模块目录被管理器换入/清理后，无需重启即可自动切换到可用的一份
  [ $((TICKS % RECHECK_EVERY)) -eq 0 ] && resolve_runtime

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
