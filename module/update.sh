#!/system/bin/sh
# 应用更新 / 回滚（不重刷模块，数据不丢）
#   9router update [版本|latest]   在线更新（官方 npm 预构建产物）
#   9router update-local <file>    安装本地 tarball
#   9router rollback               回滚到上一版本
MODDIR=${MODDIR:-$(dirname "$0")}
DATA=/data/adb/9router
TMP=$DATA/tmp
NODE=$MODDIR/runtime/bin/node.bin
export LD_LIBRARY_PATH=$MODDIR/runtime/lib

mkdir -p "$TMP" 2>/dev/null
CUR=$(cat "$DATA/current-version" 2>/dev/null)
PREV=$(cat "$DATA/prev-version" 2>/dev/null)

switch_to() { # $1=版本
  rm -f "$MODDIR/app" 2>/dev/null
  # 相对软链：与 customize.sh 保持一致，模块目录整体移动后依然有效
  ln -s "versions/$1/app" "$MODDIR/app"
  echo "$CUR" > "$DATA/prev-version"
  echo "$1" > "$DATA/current-version"
  printf 'restart' > "$DATA/control-request"
}

wait_healthy() { # 60s 内探活
  i=0
  . "$DATA/env.sh"
  while [ $i -lt 12 ]; do
    sleep 5
    code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://127.0.0.1:${APP_PORT:-20128}/v1/models" 2>/dev/null)
    if [ "$code" = "200" ] || [ "$code" = "307" ]; then echo healthy; return 0; fi
    i=$((i + 1))
  done
  echo unhealthy
  return 1
}

install_tgz() { # $1=tarball $2=版本
  [ -s "$1" ] || { echo "包不存在或为空: $1"; return 1; }
  work="$TMP/unpack.$$"
  rm -rf "$work"; mkdir -p "$work"
  tar xzf "$1" -C "$work" || { echo "解包失败"; rm -rf "$work"; return 1; }
  src="$work/package/app"
  [ -d "$src" ] || src="$work/app"
  [ -d "$src" ] || { echo "包结构不符：找不到 app 目录"; rm -rf "$work"; return 1; }
  mkdir -p "$MODDIR/versions/$2"
  rm -rf "$MODDIR/versions/$2/app"
  mv "$src" "$MODDIR/versions/$2/app"
  rm -rf "$work"
  rm -rf "$MODDIR/versions/$2/app/cli"   # 官方包里的打包机残留
  return 0
}

do_update() { # $1=版本
  ver="$1"
  [ -n "$ver" ] || { echo "需要版本号"; return 1; }
  if [ -d "$MODDIR/versions/$ver/app" ] && [ "$ver" = "$CUR" ]; then
    echo "当前已是 $ver（如需重装请先删除 $MODDIR/versions/$ver）"; return 0
  fi
  meta="$TMP/meta-$ver.json"
  tgz="$TMP/9router-$ver.tgz"
  proxy_args=""
  [ -n "${UPDATE_PROXY:-}" ] && proxy_args="--proxy $UPDATE_PROXY"
  curl -fsSL --max-time 60 $proxy_args -o "$meta" "https://registry.npmjs.org/9router/$ver" || { echo "获取元数据失败"; return 1; }

  tarball=$("$NODE" -e "console.log(JSON.parse(require('fs').readFileSync('$meta','utf8')).dist.tarball)")
  expect=$("$NODE" -e "console.log(JSON.parse(require('fs').readFileSync('$meta','utf8')).dist.integrity)")
  echo "下载: $tarball"
  curl -fsSL --max-time 600 $proxy_args -o "$tgz" "$tarball" || { echo "下载失败"; return 1; }
  got=$("$NODE" -e "console.log('sha512-'+require('crypto').createHash('sha512').update(require('fs').readFileSync('$tgz')).digest('base64'))")
  [ "$got" = "$expect" ] || { echo "完整性校验失败"; return 1; }
  echo "校验通过"
  install_tgz "$tgz" "$ver" || return 1
  rm -f "$tgz"
  cp -a "$DATA/data/db" "$DATA/backups/db-$(date +%s)" 2>/dev/null
  switch_to "$ver"
  if [ "$(wait_healthy)" = "healthy" ]; then echo "已更新到 $ver 并重启成功"; else
    echo "新版本未通过健康检查，正在回滚"
    [ -n "$PREV" ] && switch_to "$PREV"
    return 1
  fi
}

case "${1:-}" in
  rollback)
    [ -n "$PREV" ] || { echo "没有可回滚的版本"; exit 1; }
    switch_to "$PREV"
    echo "已回滚到 $PREV"
    ;;
  update)
    target="${2:-latest}"
    [ "$target" = "latest" ] && target=$(curl -fsSL --max-time 30 "https://registry.npmjs.org/9router/latest" | "$NODE" -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>console.log(JSON.parse(s).version))")
    echo "目标版本: $target (当前: ${CUR:-未知})"
    do_update "$target"
    ;;
  local)
    file="${2:-}"
    [ -s "$file" ] || { echo "用法: 9router update-local <tarball>"; exit 1; }
    base=$(basename "$file" .tgz)
    ver=${base#9router-}
    [ -n "$ver" ] || ver="local-$(date +%s)"
    install_tgz "$file" "$ver" || exit 1
    switch_to "$ver"
    echo "已从本地包安装 $ver"
    ;;
  *)
    case "${1:-}" in
      [0-9]*) do_update "$1" ;;   # 容错：直接给版本号也按更新处理
      *) echo "用法: update [版本|latest] | update-local <file> | rollback"; exit 1 ;;
    esac
    ;;
esac
