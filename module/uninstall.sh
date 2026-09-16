#!/system/bin/sh
# 卸载模块：先干净地停掉所有进程；数据目录默认保留
DATA=/data/adb/9router

for f in 9router.pid panel.pid supervisor.pid; do
  P=$(cat "$DATA/$f" 2>/dev/null)
  [ -n "$P" ] && kill "$P" 2>/dev/null
  rm -f "$DATA/$f"
done

if [ "${1:-}" = "purge" ]; then
  rm -rf "$DATA"
  echo "  已删除数据目录 $DATA"
else
  echo "  数据保留在 $DATA（配置/数据库/日志）"
  echo "  如需彻底清除: rm -rf $DATA"
fi
