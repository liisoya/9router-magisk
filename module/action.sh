#!/system/bin/sh
# Magisk / KernelSU 里点击模块「操作」时显示的内容
MODDIR=${0%/*}
DATA=/data/adb/9router
[ -f "$DATA/env.sh" ] && . "$DATA/env.sh"

CORE=$(cat "$DATA/9router.pid" 2>/dev/null)
if [ -n "$CORE" ] && kill -0 "$CORE" 2>/dev/null; then
  STAT="运行中 (PID $CORE, $(awk '/VmRSS/{printf "%.0fMB", $2/1024}' /proc/$CORE/status 2>/dev/null))"
else
  STAT="已停止"
fi
IP=$(toybox ip addr 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -1)

echo "  9Router $(cat "$DATA/current-version" 2>/dev/null || echo '未知版本')"
echo "  状态: $STAT"
echo "  监听: ${BIND_HOST:-0.0.0.0}:${APP_PORT:-20128}"
echo "  初始密码: ${INITIAL_PASSWORD:-123456}"
[ -n "$IP" ] && echo "  Dashboard: http://$IP:${APP_PORT:-20128}/dashboard"
[ -n "$IP" ] && echo "  控制面板 : http://$IP:${UI_PORT:-20129}"
[ -n "$IP" ] && echo "  API      : http://$IP:${APP_PORT:-20128}/v1"
echo ""
echo "  终端命令: 9router status | restart | update | setpw <密码> | lan on|off"
