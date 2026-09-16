#!/usr/bin/env bash
# 构建脚本公共部分：版本号、路径、下载与校验
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# shellcheck disable=SC1091
. "$ROOT/versions.env"

CACHE="$ROOT/.cache"
DEB_CACHE="$CACHE/termux"
APP_CACHE="$CACHE/npm"
STAGE="$ROOT/.stage"
DIST="$ROOT/dist"
MODULE_ID=9router

# 日志走 stderr，避免污染 $(download_deb ...) 这类命令替换的返回值
info() { printf "\033[36m[build]\033[0m %s\n" "$*" >&2; }
warn() { printf "\033[33m[warn]\033[0m %s\n" "$*" >&2; }
die() { printf "\033[31m[fail]\033[0m %s\n" "$*" >&2; exit 1; }

mkdir -p "$DEB_CACHE" "$APP_CACHE" "$STAGE" "$DIST"

# curl 包装：直连失败才走代理
fetch() {
  local url="$1" out="$2"
  if [ -f "$out" ]; then info "已缓存 $(basename "$out")"; return 0; fi
  if curl -fsSL --retry 2 --max-time 300 -o "$out.part" "$url" 2>/dev/null; then
    mv "$out.part" "$out"
  elif [ -n "${PROXY:-}" ] && curl -fsSL --proxy "$PROXY" --retry 2 --max-time 300 -o "$out.part" "$url"; then
    warn "直连失败，已通过代理 $PROXY 获取"
    mv "$out.part" "$out"
  else
    rm -f "$out.part"
    die "下载失败: $url"
  fi
}

sha256_of() { sha256sum "$1" | awk '{print $1}'; }
sha512_of() { sha512sum "$1" | awk '{print $1}'; }

# npm integrity (sha512-<base64>) 校验
verify_integrity() {
  local file="$1" expect="$2" got
  got="sha512-$(openssl dgst -sha512 -binary "$file" | openssl base64 -A)"
  [ "$got" = "$expect" ] || die "完整性校验失败: $file
  期望: $expect
  实际: $got"
}

version_code() {
  # 0.5.75-r1 -> 50751
  local ver="$1" rev="$2"
  local major minor patch
  IFS='.' read -r major minor patch <<<"$ver"
  patch="${patch%%-*}"
  echo $(( (minor * 1000 + patch) * 10 + rev ))
}
