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
# 运行时镜像：在数据区再存一份 node（模块目录被管理器清理时靠它续命）。
# 不需要这份保险可改成 0（然后删掉 /data/adb/9router/runtime 回收约 88MB）
RUNTIME_MIRROR=1
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

# 4.5) 运行时镜像 + CLI 副本（都在数据区，模块管理器不会碰）
# 背景：runtime 只放在 /data/adb/modules/<id> 里是单点——带模块镜像的 KernelSU 分支
# 在换入/清理模块目录时曾把里面的大文件弄丢（node.bin ≈ 45MB 最常见），
# 结果就是"重启一次后 core 起不来: runtime/bin/node.bin: No such file or directory"。
# 这里在数据区再放一份：supervisor.sh 优先用这一份，并会在开机时与模块自带的那份互相补齐。
if [ -f "$MODDIR/runtime/bin/node.bin" ]; then
  ui_print "  镜像 node 运行时到 $DATA/runtime（模块目录被清理时靠它续命）"
  mkdir -p "$DATA/runtime/bin" "$DATA/runtime/lib" "$DATA/bin" 2>/dev/null
  cp "$MODDIR/runtime/bin/node.bin" "$DATA/runtime/bin/node.bin" 2>/dev/null
  chmod 0755 "$DATA/runtime/bin/node.bin" 2>/dev/null
  for _f in "$MODDIR"/runtime/lib/*; do
    [ -f "$_f" ] && cp "$_f" "$DATA/runtime/lib/" 2>/dev/null
  done
  [ -s "$DATA/runtime/bin/node.bin" ] || ui_print "  ! 运行时镜像写入失败（不影响本次安装，但少了这份保险）"
  # CLI 也留一份：模块目录被清空时仍能执行 `9router doctor`
  cp "$MODDIR/system/bin/9router" "$DATA/bin/9router" 2>/dev/null
  chmod 0755 "$DATA/bin/9router" 2>/dev/null
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
#    ⚠️ 清理必须带校验：只删"确认就是那个旧 ID 模块"的真目录。
#    绝不对软链/镜像动手（曾出现旧目录下次开机又被镜像出来的情况，
#    若无条件 `rm -rf`，一旦它与自身模块目录存在别名关系，就等于把自己的模块删了）。
LEGACY=/data/adb/modules/9router
if [ -d "$LEGACY" ] && [ ! -L "$LEGACY" ] && [ "$MODDIR" != "$LEGACY" ]; then
  if [ -f "$LEGACY/module.prop" ] && grep -q '^id=9router' "$LEGACY/module.prop" 2>/dev/null; then
    ui_print "  检测到旧模块目录 $LEGACY（旧 ID 数字开头，在 ReSukiSU/KernelSU-Next 等分支上不可用）"
    for f in supervisor.pid 9router.pid panel.pid; do
      P=$(cat "$DATA/$f" 2>/dev/null)
      [ -n "$P" ] && kill "$P" 2>/dev/null
    done
    rm -rf "$LEGACY" 2>/dev/null
    ui_print "  旧模块已移除；数据仍保留在 $DATA"
  else
    ui_print "  ! $LEGACY 已存在但不是旧 ID 模块的内容，未做任何删除（请自行确认后处理）"
  fi
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
