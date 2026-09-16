#!/usr/bin/env bash
# 查询上游最新版（只读；不会自动改 versions.env，除非显式 --bump）
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/common.sh"

meta="$CACHE/npm-latest.json"
rm -f "$meta"
fetch "https://registry.npmjs.org/9router/latest" "$meta"

latest=$(python3 -c "import json;print(json.load(open('$meta'))['version'])")
published=$(python3 -c "
import json,urllib.request
d=json.load(open('$meta'))
print(d.get('dist',{}).get('tarball',''))")

echo "当前 versions.env : $APP_VERSION-r$MODULE_REV"
echo "上游最新          : $latest"
echo "tarball           : $published"

if [ "$latest" = "$APP_VERSION" ]; then
  echo "结论: 已是最新，无需更新"
  exit 0
fi

echo "结论: 有更新可用"
if [ "${1:-}" = "--bump" ]; then
  sed -i "s/^APP_VERSION=.*/APP_VERSION=$latest/" "$ROOT/versions.env"
  sed -i "s/^MODULE_REV=.*/MODULE_REV=1/" "$ROOT/versions.env"
  echo "已更新 versions.env -> APP_VERSION=$latest, MODULE_REV=1"
  echo "下一步: bash tools/fetch-app.sh && bash tools/build-module.sh"
fi
