#!/usr/bin/env bash
# 组装模块 zip（Magisk / KernelSU 通用）
# 依赖: tools/fetch-runtime.sh 与 tools/fetch-app.sh 已执行
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/common.sh"

runtime="$STAGE/runtime"
app="$STAGE/versions/$APP_VERSION/app"
[ -d "$runtime" ] || die "缺少运行时，请先运行 tools/fetch-runtime.sh"
[ -f "$app/custom-server.js" ] || die "缺少 $APP_VERSION 应用产物，请先运行 tools/fetch-app.sh"

ver="$APP_VERSION-r$MODULE_REV"
code=$(version_code "$APP_VERSION" "$MODULE_REV")
# 每次构建用全新目录（避免覆盖式复制把 app 再拷成 app/app，也避免需要批量删除）
stamp=$(date +%Y%m%d%H%M%S)
mod="$DIST/$MODULE_ID-$ver-b$stamp"

info "组装 $ver (versionCode=$code)"
mkdir -p "$mod"

# 1) 模块脚本
cp -a "$ROOT/module/." "$mod/"
rm -rf "$mod/.gitkeep"

# 2) 运行时
mkdir -p "$mod/runtime"
cp -a "$runtime/." "$mod/runtime/"

# 3) 应用产物
mkdir -p "$mod/versions/$APP_VERSION/app"
cp -a "$app/." "$mod/versions/$APP_VERSION/app/"
echo "$APP_VERSION" > "$mod/default-version"

# 4) 离线更新用的官方包（可直接 9router update-local）
[ -f "$APP_CACHE/9router-$APP_VERSION.tgz" ] && \
  cp "$APP_CACHE/9router-$APP_VERSION.tgz" "$DIST/9router-$APP_VERSION.tgz"

# 5) module.prop（含 updateJson，供管理器检查模块更新）
zip_name="${ZIP_BASENAME}-${ver}.zip"
cat > "$mod/module.prop" <<EOF
id=$MODULE_ID
name=9Router AI 网关
version=$ver
versionCode=$code
author=$GITHUB_REPO
description=在安卓上常驻运行 9Router（$APP_VERSION）。Dashboard 密码: 123456 | 面板 http://<手机IP>:20129
updateJson=https://raw.githubusercontent.com/$GITHUB_REPO/main/update.json
EOF

# 5.1) 生成仓库根目录的 update.json（Magisk/KernelSU 按它判断模块更新）
cat > "$ROOT/update.json" <<EOF
{
  "version": "$ver",
  "versionCode": $code,
  "zipUrl": "https://github.com/$GITHUB_REPO/releases/latest/download/$zip_name",
  "changelog": "https://github.com/$GITHUB_REPO/releases/tag/v$ver"
}
EOF

# 6) 权限
find "$mod" -type d -exec chmod 0755 {} +
find "$mod" -type f -exec chmod 0644 {} +
chmod 0755 "$mod/runtime/bin/node.bin"
chmod 0755 "$mod/system/bin/9router" 2>/dev/null || true
for s in customize.sh service.sh supervisor.sh action.sh uninstall.sh update.sh; do
  chmod 0755 "$mod/$s"
done

size=$(du -sh "$mod" | awk '{print $1}')
out="$DIST/$zip_name"
rm -f "$out"
# 关键：必须把模块目录的“内容”打进 zip 根目录（module.prop 位于归档根，
# 不能带顶层目录），否则 Magisk / KernelSU 会报
# "SPECIFIC FILE NOT FOUND IN archive" / 找不到 module.prop
( cd "$mod" && zip -9 -q -r "$out" . ) || die "打包失败（需要 zip）"

info "模块目录: $mod ($size)"
info "刷机包  : $out ($(du -h "$out" | awk '{print $1}'))"
