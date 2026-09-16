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
# 核心内存：老生代上限 + 额外 V8 参数（半新生代调小可省约 10MB；
# 想再省 ~9MB 可追加 --optimize-for-size，代价是 GC 更积极）
MAX_OLD_SPACE=512
CORE_NODE_FLAGS=--max-semi-space-size=4
UV_THREADPOOL_SIZE=2
# 控制面板（20129）：不用时关掉可省约 40MB 内存（9router ui off）
PANEL=1
# 健康检查间隔（秒），调大可减少探测开销
HEALTH_INTERVAL=60
EOF
  echo "JWT_SECRET=$JWT" >> "$DATA/env.sh"
fi
chmod 0600 "$DATA/env.sh"

# 4) 应用版本软链（随热更新切换）
VER=$(cat "$MODDIR/default-version" 2>/dev/null || cat "$MODDIR/version.txt" 2>/dev/null)
[ -n "$VER" ] || VER=$(ls "$MODDIR/versions" 2>/dev/null | sort -V | tail -1)
if [ -n "$VER" ] && [ -d "$MODDIR/versions/$VER/app" ]; then
  rm -f "$MODDIR/app" 2>/dev/null
  # 必须用相对软链：安装/更新时 $MODDIR 可能是暂存目录
  # （Magisk 的 /data/adb/modules_update/<id>、KernelSU 分支的模块镜像），
  # 绝对路径在内容换入正式目录后会变成悬空链接，导致 app/custom-server.js 找不到。
  ln -s "versions/$VER/app" "$MODDIR/app"
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

# 6) 旧 ID 迁移：早期版本 id=9router（数字开头），ReSukiSU / KernelSU-Next 会以
#    "Invalid module ID" 拒绝安装与卸载，且开机不执行它的 service.sh。
#    这里把旧模块目录整体移除，数据区 $DATA 保持不变，用户配置不丢。
LEGACY=/data/adb/modules/9router
if [ -d "$LEGACY" ] && [ "$MODDIR" != "$LEGACY" ]; then
  ui_print "  检测到旧模块目录 $LEGACY（旧 ID 在 ReSukiSU 上不可用）"
  for f in supervisor.pid 9router.pid panel.pid; do
    P=$(cat "$DATA/$f" 2>/dev/null)
    [ -n "$P" ] && kill "$P" 2>/dev/null
  done
  rm -rf "$LEGACY" 2>/dev/null
  ui_print "  旧模块已移除；数据仍保留在 $DATA"
fi

# 7) 旧进程清理，随后由 service.sh 拉起
kill $(cat "$DATA/9router.pid" 2>/dev/null) 2>/dev/null
kill $(cat "$DATA/panel.pid" 2>/dev/null) 2>/dev/null
kill $(cat "$DATA/supervisor.pid" 2>/dev/null) 2>/dev/null
rm -f "$DATA/9router.pid" "$DATA/panel.pid" "$DATA/supervisor.pid" 2>/dev/null

ui_print "  Web 面板:  http://<手机IP>:20128/dashboard"
ui_print "  兼容 API:  http://<手机IP>:20128/v1"
ui_print "  默认密码:  123456（可在面板修改，模块详情页会显示当前密码）"
ui_print "  完成，重启后在 KernelSU/Magisk 中查看状态"
