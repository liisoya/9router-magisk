#!/system/bin/sh
# 开机自启入口：只负责后台拉起守护进程，绝不阻塞开机流程
MODDIR=${0%/*}
DATA=/data/adb/9router
SUP=$MODDIR/supervisor.sh
LOG=$DATA/log/service.log

mkdir -p "$DATA/log" 2>/dev/null
chmod 0755 "$SUP" 2>/dev/null

mlog() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# 旧 ID 残留自愈（必须放在"避免重复实例"之前）：
# 带模块镜像的 KernelSU 分支在某些安装序列下，会把已删除的旧模块目录
# （/data/adb/modules/9router）在下一次开机时重新镜像出来。它的 service.sh
# 会先于本模块执行，抢占 20128/20129 并占用共享的 supervisor.pid，
# 导致本模块因"已有实例"直接退出。这里先停掉它并彻底清除。
LEGACY=/data/adb/modules/9router
if [ -d "$LEGACY" ] && [ "$MODDIR" != "$LEGACY" ]; then
  mlog "发现旧模块残留目录 $LEGACY，正在清理"
  for f in supervisor.pid 9router.pid panel.pid; do
    LP=$(cat "$DATA/$f" 2>/dev/null)
    [ -n "$LP" ] && kill "$LP" 2>/dev/null
  done
  # 兜底：按命令行路径清掉该目录下残留的进程
  for d in /proc/[0-9]*; do
    C=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
    case "$C" in *"$LEGACY/"*) kill "${d#/proc/}" 2>/dev/null ;; esac
  done
  sleep 2
  touch "$LEGACY/remove" 2>/dev/null
  rm -rf "$LEGACY" 2>/dev/null
  rm -f "$DATA/supervisor.pid" "$DATA/9router.pid" "$DATA/panel.pid" 2>/dev/null
  mlog "旧模块残留已清除"
fi

# 避免重复实例
if [ -f "$DATA/supervisor.pid" ]; then
  OLD=$(cat "$DATA/supervisor.pid" 2>/dev/null)
  if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null; then exit 0; fi
fi

if command -v setsid >/dev/null 2>&1; then
  setsid "$SUP" </dev/null >/dev/null 2>&1 &
else
  nohup "$SUP" </dev/null >/dev/null 2>&1 &
fi
echo $! > "$DATA/supervisor.pid"

# adb shell 起的进程会被系统回收，重新挂到 init 会话下更稳
sleep 1
exit 0
