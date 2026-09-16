#!/usr/bin/env bash
# 从官方 npm 取指定版本的预构建服务端产物（等价于上游发版内容，无需自行构建）
# 产出: .stage/versions/<version>/  （即 custom-server.js / server.js / .next-* / public / node_modules ...）
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/common.sh"

command -v openssl >/dev/null || die "需要 openssl"

ver="${1:-$APP_VERSION}"
meta="$APP_CACHE/9router-$ver.json"
tgz="$APP_CACHE/9router-$ver.tgz"

info "查询 npm 元数据 9router@$ver"
fetch "https://registry.npmjs.org/9router/$ver" "$meta"

tarball=$(python3 -c "import json,sys;print(json.load(open('$meta'))['dist']['tarball'])")
expect=$(python3 -c "import json,sys;print(json.load(open('$meta'))['dist']['integrity'])")

info "下载 $tarball"
fetch "$tarball" "$tgz"
verify_integrity "$tgz" "$expect"
info "完整性校验通过 (sha512)"

dest="$STAGE/versions/$ver"
rm -rf "$dest"; mkdir -p "$dest"
info "解包到 $dest"
tar xzf "$tgz" -C "$dest" package/app
mv "$dest/package/app" "$dest/app.stage" && rm -rf "$dest/package" && mv "$dest/app.stage" "$dest/app" 2>/dev/null || {
  # 少数版本可能把产物直接放在 package 根
  [ -d "$dest/app" ] || mv "$dest/package" "$dest/app"
}

# 官方包里残留了打包机器的 ~/（含它的 db / jwt-secret / machine-id），必须删掉：
# 否则所有安装者共享同一个 machine-id（云同步会串号）
if [ -d "$dest/app/cli" ]; then
  info "清理打包机残留 app/cli"
  rm -rf "$dest/app/cli"
fi

for must in custom-server.js server.js public node_modules; do
  [ -e "$dest/app/$must" ] || die "产物不完整，缺少 $must（上游可能换了目录结构，请检查）"
done
find "$dest/app" -maxdepth 1 -name ".next*" -type d | head -1 | grep -q . || die "找不到 .next-* 构建目录"

info "应用就绪: $ver ($(du -sh "$dest/app" | awk '{print $1}'))"
