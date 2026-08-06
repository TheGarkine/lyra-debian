#!/usr/bin/env bash
# Fetch kernel, U-Boot and rkbin into cache/src (shallow, idempotent) and
# record the resolved SHAs in out/manifest.txt.
source "$(dirname "$0")/lib.sh"

# fetch <dir> <url> <branch> <ref>
# ref empty  -> shallow clone of branch tip (updated on re-run)
# ref set    -> shallow fetch of exactly that commit (pinned)
fetch() {
    local dir="$SRC_DIR/$1" url="$2" branch="$3" ref="$4"
    if [ ! -d "$dir/.git" ]; then
        log "cloning $url ($branch${ref:+ @ $ref})"
        if [ -n "$ref" ]; then
            git init -q "$dir"
            git -C "$dir" remote add origin "$url"
            git -C "$dir" fetch --depth 1 origin "$ref"
            git -C "$dir" checkout -q FETCH_HEAD
        else
            git clone --depth 1 -b "$branch" "$url" "$dir"
        fi
    elif [ -n "$ref" ]; then
        if [ "$(git -C "$dir" rev-parse HEAD)" != "$ref" ]; then
            log "updating $1 to pinned $ref"
            git -C "$dir" fetch --depth 1 origin "$ref"
            git -C "$dir" checkout -q FETCH_HEAD
        fi
    else
        log "updating $1 ($branch tip)"
        git -C "$dir" fetch --depth 1 origin "$branch"
        git -C "$dir" checkout -q FETCH_HEAD
    fi
}

fetch kernel "$KERNEL_URL" "$KERNEL_BRANCH" "$KERNEL_REF"
fetch u-boot "$UBOOT_URL"  "$UBOOT_BRANCH"  "$UBOOT_REF"
fetch rkbin  "$RKBIN_URL"  "$RKBIN_BRANCH"  "$RKBIN_REF"

# Rockchip update.img pack tools (x86_64 prebuilts; not in rkbin — the SDK
# ships them in Linux_Pack_Firmware, mirrored in the luckfox-pico repo).
PACK_TOOLS="$ROOT/cache/tools"
mkdir -p "$PACK_TOOLS"
for tool in afptool rkImageMaker; do
    if [ ! -x "$PACK_TOOLS/$tool" ]; then
        log "fetching $tool"
        curl -fsSL -o "$PACK_TOOLS/$tool" \
            "https://raw.githubusercontent.com/LuckfoxTECH/luckfox-pico/main/tools/linux/Linux_Pack_Firmware/$tool"
        chmod +x "$PACK_TOOLS/$tool"
    fi
done

{
    echo "# resolved sources — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for r in kernel u-boot rkbin; do
        echo "$r $(git -C "$SRC_DIR/$r" rev-parse HEAD)"
    done
} > "$OUT_DIR/manifest.txt"

log "manifest:"
cat "$OUT_DIR/manifest.txt"
