#!/bin/bash
# verify_vendor.sh — 校验 vendor 引擎成品与包版本同源
#
#   ./tools/verify_vendor.sh              # 校验 manifest 里的全部 variant
#   ./tools/verify_vendor.sh rootless     # 只校验一个
#
# 只依赖 awk / wc / shasum(或 sha256sum) —— 故意不依赖 Xcode，
# 这样在任何一台机器上都能跑，不用等打包环境齐了才发现引擎是旧的。
#
# 为什么需要它：Makefile 的 VERSION 与 vendor 里的 decrypt_helper.dylib 是两套
# 独立演进的东西。曾经出现过「包版本 1.27.5，包内引擎还是 1.25.6」的漂移：
# 装出来的包自称新版，实际引擎仍是旧的（旧引擎网络捕获只到 HTTP 层，传输层
# TLS/socket 完全没有），而且没有任何一步会报错。
#
# 退出码：0 = 全部通过；1 = 有漂移/损坏；2 = 用法或环境问题

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$SCRIPT_DIR/vendor/dylib"
MANIFEST="$VENDOR_DIR/manifest.txt"
MAKEFILE="$SCRIPT_DIR/Makefile"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
bad()  { echo -e "${RED}[✗]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

die() { bad "$1"; exit "${2:-1}"; }

[ -f "$MANIFEST" ] || die "缺少清单: $MANIFEST" 2
[ -f "$MAKEFILE" ] || die "缺少 Makefile: $MAKEFILE" 2

VERSION=$(grep '^VERSION' "$MAKEFILE" | head -1 | sed 's/.*:= *//')
[ -n "$VERSION" ] || die "无法从 Makefile 读出 VERSION" 2

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        die "找不到 shasum 或 sha256sum" 2
    fi
}

# manifest_field <variant> <field>  (2=version 3=archs 4=bytes 5=sha256 6=provenance)
manifest_field() {
    awk -v v="$1" -v f="$2" \
        '!/^[[:space:]]*#/ && NF >= 6 && $1 == v { print $f; exit }' "$MANIFEST"
}

# manifest 里出现过的 variant（保持文件顺序，去重）
manifest_variants() {
    awk '!/^[[:space:]]*#/ && NF >= 6 { print $1 }' "$MANIFEST" | awk '!seen[$0]++'
}

if [ "$#" -gt 0 ]; then
    VARIANTS="$*"
else
    VARIANTS=$(manifest_variants)
fi
[ -n "$VARIANTS" ] || die "manifest 里没有任何 variant 记录" 2

echo "包版本 (Makefile VERSION) = $VERSION"
echo "清单     $MANIFEST"
echo

FAILED=0
for VARIANT in $VARIANTS; do
    DYLIB="$VENDOR_DIR/$VARIANT/decrypt_helper.dylib"
    M_VERSION=$(manifest_field "$VARIANT" 2)
    M_ARCHS=$(manifest_field "$VARIANT" 3)
    M_BYTES=$(manifest_field "$VARIANT" 4)
    M_SHA=$(manifest_field "$VARIANT" 5)
    M_FROM=$(manifest_field "$VARIANT" 6)

    if [ -z "$M_VERSION" ]; then
        bad "[$VARIANT] manifest 无记录（需要 6 个字段，见文件头注释）"
        FAILED=1; continue
    fi
    if [ ! -f "$DYLIB" ]; then
        bad "[$VARIANT] 缺少成品: $DYLIB"
        FAILED=1; continue
    fi

    ERR=""
    [ "$M_VERSION" = "$VERSION" ] || ERR="$ERR
      版本漂移: 包=$VERSION 引擎=$M_VERSION"

    ACTUAL_BYTES=$(wc -c < "$DYLIB" | tr -d ' ')
    [ "$ACTUAL_BYTES" = "$M_BYTES" ] || ERR="$ERR
      体积不符: 实际=$ACTUAL_BYTES manifest=$M_BYTES"

    ACTUAL_SHA=$(sha256_of "$DYLIB")
    [ "$ACTUAL_SHA" = "$M_SHA" ] || ERR="$ERR
      SHA-256 不符: 实际=$ACTUAL_SHA manifest=$M_SHA"

    if [ -n "$ERR" ]; then
        bad "[$VARIANT] 校验失败 ($M_ARCHS, 应为 v$M_VERSION, 取自 $M_FROM)$ERR"
        FAILED=1
    else
        ok "[$VARIANT] v$M_VERSION $M_ARCHS $ACTUAL_BYTES bytes 取自 $M_FROM"
    fi
done

echo
if [ "$FAILED" -ne 0 ]; then
    cat >&2 <<'EOF'
引擎与包版本不同源。两种修法：
  1) 把引擎升到包版本：更新 vendor/dylib/<variant>/decrypt_helper.dylib
     与 vendor/dylib/manifest.txt（流程见 vendor/dylib/README.md）
  2) 把 Makefile 的 VERSION 改回引擎实际版本

不要放着不管 —— 这会让用户装上「自称新版、实际旧引擎」的包。
EOF
    exit 1
fi

ok "全部 variant 通过"
