#!/system/bin/sh
# 9Router Magisk/KernelSU 模块 - 安装后置处理（采用标准解压，不依赖 busybox tar）
# 安装时被 Magisk/KernelSU 置好的 $MODPATH；手动执行时退化到脚本所在目录
MODDIR=${MODPATH:-${0%/*}}
DATA=/data/adb/9router

ui_print "  9Router 网关模块"

# 1) 架构校验：只支持 arm64
ABI=$(getprop ro.product.cpu.abi 2>/dev/null)
case "$ABI" in
  arm64*) ;;
  *) abort "  不支持当前架构: $ABI（仅 arm64-v8a）" ;;
esac

# 2) 数据区（放在模块外，更新/重装不会丢数据）
rm -f "$DATA/env.sh.tmp" 2>/dev/null
mkdir -p "$DATA/data" "$DATA/tmp" "$DATA/log" "$DATA/backups" 2>/dev/null
chmod 0711 "$DATA" 2>/dev/null
chmod 0700 "$DATA/data" 2>/dev/null

# 3) 默认配置 + 随机 JWT（密码沿用官方默认 123456，可在面板修改）
if [ ! -f "$DATA/env.sh" ]; then
  ui_print "  生成默认配置"
  JWT=$(head -c 48 /dev/urandom | tr -dc 'a-f0-9' 2>/dev/null)
  [ -n "$JWT" ] || JWT=$(date +%s)$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  cat > "$DATA/env.sh" <<EOF
APP_PORT=20128
UI_PORT=20129
BIND_HOST=0.0.0.0
REQUIRE_API_KEY=false
API_KEY=
INITIAL_PASSWORD=123456
MAX_OLD_SPACE=512
UV_THREADPOOL_SIZE=2
PANEL=1
EOF
  echo "JWT_SECRET=$JWT" >> "$DATA/env.sh"
fi
chmod 0600 "$DATA/env.sh"

# 4) 应用版本软链（随热更新切换）
VER=$(cat "$MODDIR/default-version" 2>/dev/null || cat "$MODDIR/version.txt" 2>/dev/null)
[ -n "$VER" ] || VER=$(ls "$MODDIR/versions" 2>/dev/null | sort -V | tail -1)
if [ -n "$VER" ] && [ -d "$MODDIR/versions/$VER/app" ]; then
  rm -f "$MODDIR/app" 2>/dev/null
  ln -s "$MODDIR/versions/$VER/app" "$MODDIR/app"
  echo "$VER" > "$DATA/current-version"
else
  abort "  找不到应用产物目录"
fi

# 5) 权限
chmod 0755 "$MODDIR"/*.sh 2>/dev/null
chmod 0755 "$MODDIR/runtime/bin/node.bin" 2>/dev/null
chmod 0644 "$MODDIR/runtime/lib"/* 2>/dev/null
chmod 0755 "$MODDIR/control-center.cjs" 2>/dev/null
[ -f "$MODDIR/system/bin/9router" ] && chmod 0755 "$MODDIR/system/bin/9router"

# 6) 旧进程清理，随后由 service.sh 拉起
kill $(cat "$DATA/9router.pid" 2>/dev/null) 2>/dev/null
kill $(cat "$DATA/panel.pid" 2>/dev/null) 2>/dev/null
rm -f "$DATA/9router.pid" "$DATA/panel.pid" 2>/dev/null

ui_print "  Web 面板:  http://<手机IP>:20128/dashboard"
ui_print "  兼容 API:  http://<手机IP>:20128/v1"
ui_print "  默认密码:  123456（可在面板修改，模块详情页会显示当前密码）"
ui_print "  完成，重启后在 KernelSU/Magisk 中查看状态"
