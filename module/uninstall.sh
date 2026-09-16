#!/system/bin/sh
# 卸载模块：先干净地停掉所有进程；数据目录默认保留
DATA=/data/adb/9router

# 只杀"确实是本模块"的进程：PID 文件可能来自上次开机且 PID 已被复用，
# 无脑 kill 会误伤别的进程
kill_if_ours() { # $1=pid 文件
  [ -f "$1" ] || return 0
  P=$(cat "$1" 2>/dev/null)
  if [ -n "$P" ] && [ -r "/proc/$P/cmdline" ]; then
    C=$(tr '\0' ' ' < "/proc/$P/cmdline" 2>/dev/null)
    case "$C" in
      *supervisor.sh*|*custom-server.js*|*control-center.cjs*) kill "$P" 2>/dev/null ;;
    esac
  fi
  rm -f "$1"
}

for f in 9router.pid panel.pid supervisor.pid; do kill_if_ours "$DATA/$f"; done
rm -f "$DATA/control-request" 2>/dev/null

# 运行时镜像 / CLI 副本是可再生的缓存（约 88MB），随模块一起清掉
rm -rf "$DATA/runtime" "$DATA/bin" 2>/dev/null

if [ "${1:-}" = "purge" ]; then
  rm -rf "$DATA"
  echo "  已删除数据目录 $DATA"
else
  echo "  数据保留在 $DATA（配置/数据库/日志；运行时缓存已清理）"
  echo "  如需彻底清除: rm -rf $DATA"
fi
