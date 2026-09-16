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
IP=$({ toybox ip addr 2>/dev/null || ip addr 2>/dev/null; } | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -1)

# 运行时状态：模块目录被管理器清理时，数据区镜像会顶上
if [ -x "$DATA/runtime/bin/node.bin" ]; then RT="数据区镜像"
elif [ -x "$MODDIR/runtime/bin/node.bin" ]; then RT="模块目录"
else RT="不可用（终端执行 9router doctor 看原因）"; fi

echo "  9Router $(cat "$DATA/current-version" 2>/dev/null || echo '未知版本')"
echo "  状态: $STAT"
echo "  运行时: $RT"
echo "  监听: ${BIND_HOST:-0.0.0.0}:${APP_PORT:-20128}"
echo "  初始密码: ${INITIAL_PASSWORD:-123456}"
[ -n "$IP" ] && echo "  Dashboard: http://$IP:${APP_PORT:-20128}/dashboard"
if [ "${PANEL:-1}" = "1" ]; then
  [ -n "$IP" ] && echo "  控制面板 : http://$IP:${UI_PORT:-20129}  (占约 30MB 内存，可关)"
else
  echo "  控制面板 : 已关闭（9router ui on 可开启）"
fi
[ -n "$IP" ] && echo "  API      : http://$IP:${APP_PORT:-20128}/v1"
echo ""
echo "  终端命令: 9router status | doctor | repair | restart | update | setpw <密码> | lan on|off | ui on|off"
