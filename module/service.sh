#!/system/bin/sh
# 开机自启入口：只负责后台拉起守护进程，绝不阻塞开机流程
MODDIR=${0%/*}
DATA=/data/adb/9router
SUP=$MODDIR/supervisor.sh

mkdir -p "$DATA/log" 2>/dev/null
chmod 0755 "$SUP" 2>/dev/null

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
