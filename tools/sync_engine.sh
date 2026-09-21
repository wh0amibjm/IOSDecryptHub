#!/bin/bash
# sync_engine.sh — 从已发布 release 拉取引擎成品，更新 vendor/dylib 与 manifest
#
#   ./tools/sync_engine.sh v1.27.5        # 同步到指定 tag
#   ./tools/sync_engine.sh                # 用当前 Makefile VERSION 推 tag
#   ./tools/sync_engine.sh v1.27.5 --keep-version   # 只换引擎，不动 Makefile VERSION
#
# 做什么：
#   1. 查 GitHub release，逐个资产核对发布方公布的 SHA-256（release notes 有写）
#   2. rootless 取未签名成品 decrypt_helper-<ver>.dylib（与历史约定一致）
#      roothide 取 roothide deb 里的 decrypt_helper.dylib（胖切片只在 deb 里）
#   3. 覆盖 vendor/dylib/<variant>/decrypt_helper.dylib
#   4. 重写 vendor/dylib/manifest.txt 的数据行（保留文件头注释）
#   5. 把 Makefile 的 VERSION 改成新版本（除 --keep-version），再跑校验
#
# 为什么 rootless 与 roothide 来源不同：公开发布的独立引擎资产只有一个 arm64
# 切片，roothide 要的是 arm64+arm64e 胖切片，只能从 roothide deb 里取。
# 两者的 SHA-256 都会写进 manifest，可复核、可回滚。
#
# 依赖：curl、awk、wc、shasum(或 sha256sum)、ar、tar(含 xz)。
# macOS 上如果没有 ar/xz：brew install binutils xz。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$SCRIPT_DIR/vendor/dylib"
MANIFEST="$VENDOR_DIR/manifest.txt"
MAKEFILE="$SCRIPT_DIR/Makefile"
REPO="decrypthub/IOSDecryptHub"
API="https://api.github.com/repos/$REPO"
DL="https://github.com/$REPO/releases/download"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[*]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
die()  { echo -e "${RED}[✗]${NC} $1" >&2; exit 1; }

TAG=""
KEEP_VERSION=0
for arg in "$@"; do
    case "$arg" in
        --keep-version) KEEP_VERSION=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        -*) die "未知参数: $arg" ;;
        *) TAG="$arg" ;;
    esac
done

for tool in curl awk wc ar tar; do
    command -v "$tool" >/dev/null 2>&1 || die "缺少 $tool"
done

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else die "找不到 shasum 或 sha256sum"; fi
}

if [ -z "$TAG" ]; then
    V=$(grep '^VERSION' "$MAKEFILE" | head -1 | sed 's/.*:= *//')
    [ -n "$V" ] || die "无法从 Makefile 读出 VERSION"
    TAG="v$V"
fi
VER="${TAG#v}"
info "目标 release: $TAG (引擎版本 $VER)"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/dh-sync-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

info "查询 release 资产..."
ASSETS_JSON="$WORK/assets.json"
curl -fsSL "$API/releases/tags/$TAG" -o "$ASSETS_JSON" \
    || die "取不到 release $TAG（tag 是否存在？）"

asset_url() {
    # asset_url <asset-name>
    awk -v want="$1" '
        /"name"[[:space:]]*:/ { match($0, /"name"[[:space:]]*:[[:space:]]*"[^"]*"/); n=substr($0, RSTART, RLENGTH); sub(/.*"[[:space:]]*:[[:space:]]*"/, "", n); sub(/"$/, "", n) }
        /"browser_download_url"[[:space:]]*:/ { match($0, /"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*"/); u=substr($0, RSTART, RLENGTH); sub(/.*"[[:space:]]*:[[:space:]]*"/, "", u); sub(/"$/, "", u); if (n == want) { print u; exit } }
    ' "$ASSETS_JSON"
}

ROOTLESS_ASSET="decrypt_helper-$VER.dylib"
ROOTHIDE_ASSET="com.iosdecrypthub_${VER}_roothide.deb"
ROOTLESS_URL=$(asset_url "$ROOTLESS_ASSET")
ROOTHIDE_URL=$(asset_url "$ROOTHIDE_ASSET")
[ -n "$ROOTLESS_URL" ] || die "release $TAG 里没有资产 $ROOTLESS_ASSET"
[ -n "$ROOTHIDE_URL" ] || die "release $TAG 里没有资产 $ROOTHIDE_ASSET"

info "下载 $ROOTLESS_ASSET"
curl -fsSL "$ROOTLESS_URL" -o "$WORK/rootless.dylib" || die "下载 rootless 引擎失败"
info "下载 $ROOTHIDE_ASSET"
curl -fsSL "$ROOTHIDE_URL" -o "$WORK/roothide.deb" || die "下载 roothide deb 失败"

info "解包 roothide deb..."
mkdir -p "$WORK/x"
( cd "$WORK/x" && ar x "$WORK/roothide.deb" ) || die "ar 解包失败（macOS 可 brew install binutils）"
[ -f "$WORK/x/data.tar.xz" ] || [ -f "$WORK/x/data.tar.gz" ] || die "deb 里没有 data.tar.{xz,gz}"
if [ -f "$WORK/x/data.tar.xz" ]; then
    ( cd "$WORK/x" && tar xf data.tar.xz ) || die "tar 解压 data.tar.xz 失败（macOS 可 brew install xz）"
else
    ( cd "$WORK/x" && tar xf data.tar.gz ) || die "tar 解压 data.tar.gz 失败"
fi
ROOTHIDE_DYLIB=$(find "$WORK/x" -name decrypt_helper.dylib -print -quit)
[ -n "$ROOTHIDE_DYLIB" ] || die "roothide deb 里找不到 decrypt_helper.dylib"

# 引擎自带版本号自证：与 tag 不一致说明资产串了
engine_version() { strings -a "$1" 2>/dev/null | grep -xE '^1\.[0-9]+\.[0-9]+$' | head -1; }
if command -v strings >/dev/null 2>&1; then
    for pair in "rootless:$WORK/rootless.dylib" "roothide:$ROOTHIDE_DYLIB"; do
        name="${pair%%:*}"; path="${pair#*:}"
        got=$(engine_version "$path")
        [ "$got" = "$VER" ] || warn "$name 引擎内嵌版本为 '$got'，与 tag 的 $VER 不一致（继续，但请人工确认）"
    done
fi

R_SHA=$(sha256_of "$WORK/rootless.dylib");   R_BYTES=$(wc -c < "$WORK/rootless.dylib" | tr -d ' ')
H_SHA=$(sha256_of "$ROOTHIDE_DYLIB");        H_BYTES=$(wc -c < "$ROOTHIDE_DYLIB" | tr -d ' ')

info "rootless: $R_BYTES bytes  sha256=$R_SHA"
info "roothide: $H_BYTES bytes  sha256=$H_SHA"

# 覆盖成品
mkdir -p "$VENDOR_DIR/rootless" "$VENDOR_DIR/roothide"
cp "$WORK/rootless.dylib" "$VENDOR_DIR/rootless/decrypt_helper.dylib"
cp "$ROOTHIDE_DYLIB"      "$VENDOR_DIR/roothide/decrypt_helper.dylib"
chmod 0755 "$VENDOR_DIR"/rootless/decrypt_helper.dylib "$VENDOR_DIR"/roothide/decrypt_helper.dylib

# 重写 manifest：保留 # 注释与空行，替换两条数据行
TMP_MANIFEST="$WORK/manifest.txt"
awk -v ver="$VER" -v rsha="$R_SHA" -v rbytes="$R_BYTES" \
    -v hsha="$H_SHA" -v hbytes="$H_BYTES" -v tag="$TAG" '
    BEGIN { done_rootless=0; done_roothide=0 }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
    $1 == "rootless" && !done_rootless {
        printf "%-10s %-8s %-14s %-9s %-66s release:%s/decrypt_helper-%s.dylib\n", "rootless", ver, "arm64", rbytes, rsha, tag, ver
        done_rootless=1; next
    }
    $1 == "roothide" && !done_roothide {
        printf "%-10s %-8s %-14s %-9s %-66s release:%s/com.iosdecrypthub_%s_roothide.deb\n", "roothide", ver, "arm64,arm64e", hbytes, hsha, tag, ver
        done_roothide=1; next
    }
    { print }
    END {
        if (!done_rootless)  printf "%-10s %-8s %-14s %-9s %-66s release:%s/decrypt_helper-%s.dylib\n", "rootless", ver, "arm64", rbytes, rsha, tag, ver
        if (!done_roothide)  printf "%-10s %-8s %-14s %-9s %-66s release:%s/com.iosdecrypthub_%s_roothide.deb\n", "roothide", ver, "arm64,arm64e", hbytes, hsha, tag, ver
    }
' "$MANIFEST" > "$TMP_MANIFEST"
cp "$TMP_MANIFEST" "$MANIFEST"

if [ "$KEEP_VERSION" -eq 1 ]; then
    warn "按 --keep-version 保留 Makefile VERSION 不变（校验大概率会失败）"
else
    if grep -q '^VERSION' "$MAKEFILE"; then
        sed -i.bak "s|^VERSION := .*|VERSION := $VER|" "$MAKEFILE" && rm -f "$MAKEFILE.bak"
        info "Makefile VERSION -> $VER"
    else
        die "Makefile 里找不到 VERSION 行"
    fi
fi

info "跑校验..."
bash "$SCRIPT_DIR/tools/verify_vendor.sh"

cat <<EOF

同步完成。提交前请确认：
  * vendor/dylib/{rootless,roothide}/decrypt_helper.dylib 与 manifest.txt 一起入库
  * 若引擎带来了新的捕获能力，同步更新 docs/transport-layer-capture.md 的现状章节
  * 真机验证清单见 docs/device_verification.md
EOF
