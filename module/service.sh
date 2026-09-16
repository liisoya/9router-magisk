#!/system/bin/sh
# 开机自启入口：只负责后台拉起守护进程，绝不阻塞开机流程
MODDIR=${0%/*}
DATA=/data/adb/9router
SUP=$MODDIR/supervisor.sh
LOG=$DATA/log/service.log

mkdir -p "$DATA/log" 2>/dev/null
chmod 0755 "$SUP" 2>/dev/null

mlog() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# ⚠️ 这里（以及任何开机阶段）**绝不删除 /data/adb/modules 下的任何东西**。
# 早期版本会在这里 `rm -rf /data/adb/modules/9router` 并写一个 remove 标记来清理旧 ID 残留，
# 但 remove 标记是"下一次开机才生效"的删除指令：一旦那个旧目录与自身模块目录存在
# 软链/镜像关系（带模块镜像的 KernelSU 分支上出现过"已删除的旧目录下次开机又被镜像出来"），
# 就等于把自己的模块目录交给管理器去删 —— 表现正是"用得好好的，重启一次后
# runtime/node.bin 就没了"。旧 ID 残留只在安装期（customize.sh）做一次带校验的清理。

# 避免重复实例：PID 文件可能来自上一次开机，且 PID 已被复用，
# 所以除了 kill -0 还要确认它真的是我们的 supervisor。
if [ -f "$DATA/supervisor.pid" ]; then
  OLD=$(cat "$DATA/supervisor.pid" 2>/dev/null)
  if [ -n "$OLD" ]; then
    CMDL=$(tr '\0' ' ' < "/proc/$OLD/cmdline" 2>/dev/null)
    case "$CMDL" in
      *supervisor.sh*) kill -0 "$OLD" 2>/dev/null && exit 0 ;;
    esac
  fi
fi

# 旧 ID 残留：只检测、只提示，不删除（删除交给用户或安装期校验过的清理）
if [ -d /data/adb/modules/9router ] && [ "$MODDIR" != "/data/adb/modules/9router" ]; then
  mlog "提示: 发现旧模块目录 /data/adb/modules/9router（不再自动删除）；确认无用后可在管理器里卸载该模块"
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
