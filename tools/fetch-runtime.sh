#!/usr/bin/env bash
# 从 Termux 官方源取下 aarch64 的 Node 与依赖，组装成可独立运行的运行时
# 产出: .stage/runtime/{bin/node.bin,lib/*.so,cacert.pem,openssl.cnf}
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/common.sh"

command -v dpkg-deb >/dev/null || die "需要 dpkg-deb"
command -v readelf  >/dev/null || die "需要 readelf"
command -v python3  >/dev/null || die "需要 python3"

INDEX="$DEB_CACHE/Packages"
[ -f "$INDEX" ] || fetch "$TERMUX_REPO/dists/$TERMUX_DIST/main/binary-$TERMUX_ARCH/Packages" "$INDEX"

out=$(mktemp -d); trap 'rm -rf "$out"' EXIT

lookup() { # <pkg> <version> -> line: filename|sha256
  python3 - "$INDEX" "$1" "$2" <<'PY'
import sys
idx, pkg, ver = sys.argv[1], sys.argv[2], sys.argv[3]
blocks = open(idx, encoding='utf-8', errors='replace').read().split('\n\n')
for b in blocks:
    d = {}
    for line in b.splitlines():
        if ': ' in line:
            k, v = line.split(': ', 1)
            d[k] = v
    if d.get('Package') == pkg and d.get('Version') == ver:
        print('%s|%s' % (d.get('Filename'), d.get('SHA256')))
        break
PY
}

presence_ok() { [ -n "${1%%|*}" ] && [ -n "${1##*|}" ] || return 1; }

download_deb() { # <pkg> <version>
  local pkg="$1" ver="$2" line filename sha got deb
  line=$(lookup "$pkg" "$ver")
  [ -n "$line" ] || die "Packages 里找不到 $pkg $ver"
  filename="${line%%|*}"; sha="${line##*|}"
  deb="$DEB_CACHE/$(basename "$filename" | tr '%:' '__')"
  fetch "$TERMUX_REPO/$filename" "$deb"
  got=$(sha256_of "$deb")
  [ "$got" = "$sha" ] || die "$pkg SHA256 不匹配
  期望: $sha
  实际: $got"
  local dir="$out/$pkg"
  mkdir -p "$dir"
  dpkg-deb -x "$deb" "$dir"
  echo "$dir"
}

info "取 nodejs-lts $NODE_VERSION"
node_dir=$(download_deb "$NODE_PACKAGE" "$NODE_VERSION")

info "取依赖包"
printf '%s\n' "$TERMUX_DEBS" | grep -v '^[[:space:]]*$' | while read -r pkg ver; do
  [ -z "${pkg:-}" ] && continue
  info "  - $pkg $ver"
  download_deb "$pkg" "$ver" >/dev/null
done

PREFIX=data/data/com.termux/files/usr
node_bin="$node_dir/$PREFIX/bin/node"
[ -f "$node_bin" ] || die "node 二进制不在预期路径: $node_bin"

# ---- 计算动态库闭包（node -> NEEDED -> 递归），并解引用 symlink ----
stage="$STAGE/runtime"
rm -rf "$stage"; mkdir -p "$stage/bin" "$stage/lib"
cp "$node_bin" "$stage/bin/node.bin"; chmod 755 "$stage/bin/node.bin"

lib_dirs=$(find "$out" -path "*$PREFIX/lib" -type d | tr '\n' ':')
IFS=':' read -ra LIBDIRS <<<"$lib_dirs"

find_lib() { local name="$1" d; for d in "${LIBDIRS[@]}"; do [ -f "$d/$name" ] && { echo "$d/$name"; return; }; done; }

declare -A COPIED
copy_lib() { # <soname>
  local name="$1" path real
  [ -n "${COPIED[$name]:-}" ] && return
  COPIED[$name]=1
  path=$(find_lib "$name") || die "找不到依赖库: $name"
  # adb push 到安卓时会破坏 symlink，因此统一实体化
  cp -L "$path" "$stage/lib/$name" 2>/dev/null || die "复制失败: $name"
  # 递归处理它自己的依赖
  while read -r dep; do
    [ -z "$dep" ] && continue
    [ -n "${COPIED[$dep]:-}" ] && continue
    copy_lib "$dep"
  done < <(readelf -d "$stage/lib/$name" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p' | grep -vE '^(libc|libm|libdl|libpthread)\.so')
}

info "解析动态依赖闭包"
while read -r need; do
  [ -z "$need" ] && continue
  copy_lib "$need"
done < <(readelf -d "$stage/bin/node.bin" | sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p' | grep -vE '^(libc|libm|libdl|libpthread)\.so')

# CA 证书 / OpenSSL 配置
for f in $(find "$out" -path "*$PREFIX/etc/tls/cert.pem" | head -1) $(find "$out" -path "*$PREFIX/etc/tls/openssl.cnf" | head -1); do
  [ -f "$f" ] && cp "$f" "$stage/lib/$(basename "$f" | sed 's/cert.pem/cacert.pem/')"
done
[ -f "$stage/lib/cacert.pem" ] || warn "未找到 CA 证书包，上游 HTTPS 可能校验失败"

size=$(du -sh "$stage" | awk '{print $1}')
info "运行时就绪: $stage ($size)"
ls -1 "$stage/lib" | sed 's/^/    lib\//' | head -20
