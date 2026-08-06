#!/usr/bin/env bash
# Build the SPI NAND firmware -> out/images/lyra-debian-nand-update.img.
# Flash with RKDevTool (Windows) or upgrade_tool in maskrom/loader mode
# (hold BOOT while plugging USB). EXPERIMENTAL until verified on hardware.
#
# NAND layout (parameter.txt, 512-byte sectors on the 256 MiB Winbond chip):
#   0x2000@0x2000  uboot   (4 MiB)   uboot.img — FIT loaded by SPL
#   0x6000@0x4000  boot    (12 MiB)  boot.img  — FIT (zImage + NAND dtb + resource)
#   grow @0x10000  rootfs  (223 MiB) rootfs.img — UBI with UBIFS volume "rootfs"
# The first 4 MiB hold the idblock loader (written by the flash tool).
#
# Boot flow: maskrom -> idblock (DDR+SPL) -> uboot.img (FIT) -> vendor bootcmd
# "boot_fit" loads boot.img from the rkparm boot partition; bootargs = DTB
# chosen node (ubi root) + mtdparts= injected by U-Boot from parameter.txt.
source "$(dirname "$0")/lib.sh"

UBOOT="$OUT_DIR/u-boot-nand"
KERNEL="$OUT_DIR/kernel"
KBUILD="$BUILD_DIR/kernel"
ROOTFS_TAR="$OUT_DIR/rootfs/lyra-rootfs-nand.tar.gz"
PACK_TOOLS="$ROOT/cache/tools"
IMAGES="$OUT_DIR/images"
WORK="$SCRATCH/image-nand"

for f in "$UBOOT/uboot.img" "$KERNEL/zImage" "$KERNEL/$DTB_NAME_NAND" \
         "$PACK_TOOLS/afptool" "$PACK_TOOLS/rkImageMaker" \
         "$ROOT/board/nand/parameter.txt"; do
    [ -f "$f" ] || die "missing: $f (run earlier stages / 01-fetch for pack tools)"
done
[ -f "$ROOTFS_TAR" ] || die "missing rootfs tarball: $ROOTFS_TAR (run 04-rootfs.sh nand)"
LOADER="$(ls "$UBOOT"/rk3506*loader*.bin 2>/dev/null | head -n1)"
[ -n "$LOADER" ] || die "missing maskrom loader .bin in $UBOOT"

rm -rf "$WORK"
mkdir -p "$WORK/pack" "$IMAGES"

# ---------------------------------------------------------------- boot.img
# Replicates the vendor kernel's `make <dts>.img` (scripts/mkimg
# make_fit_boot_img): FIT per kernel-tree boot.its with kernel=zImage,
# fdt=NAND dtb, resource=resource.img (resource_tool-packed dtb).
log "building boot.img (FIT: zImage + $DTB_NAME_NAND + resource)"
BOOTW="$WORK/boot"
mkdir -p "$BOOTW/out"
cp "$KERNEL/zImage"         "$BOOTW/out/kernel"
cp "$KERNEL/$DTB_NAME_NAND" "$BOOTW/out/fdt"

RESOURCE_TOOL="$KBUILD/scripts/resource_tool"
[ -x "$RESOURCE_TOOL" ] || die "resource_tool not built at $RESOURCE_TOOL (run 03-kernel.sh)"
( cd "$BOOTW" && "$RESOURCE_TOOL" "$KERNEL/$DTB_NAME_NAND" >/dev/null )
mv "$BOOTW/resource.img" "$BOOTW/out/resource"

# The its must live next to the staged files: mkimage resolves its
# /incbin/("fdt") references relative to the .its file's directory.
sed -e 's/arch = ""/arch = "arm"/g' -e 's/compression = ""/compression = "none"/' \
    "$SRC_DIR/kernel/boot.its" > "$BOOTW/out/boot.its"
# rkbin's mkimage (same one the SDK uses); container binfmt runs the x86_64 tool.
RKMKIMAGE="$SRC_DIR/rkbin/tools/mkimage"
[ -x "$RKMKIMAGE" ] || RKMKIMAGE=mkimage
"$RKMKIMAGE" -E -p 0x800 -f "$BOOTW/out/boot.its" "$WORK/pack/boot.img" >/dev/null

# --------------------------------------------------------------- rootfs.img
log "building rootfs.img (UBIFS in UBI, PEB=$NAND_PEB_SIZE page=$NAND_PAGE_SIZE)"
ROOTFS_DIR="$WORK/rootfs"
mkdir -p "$ROOTFS_DIR"
tar --numeric-owner -xzf "$ROOTFS_TAR" -C "$ROOTFS_DIR"

log "injecting kernel modules ($(cat "$OUT_DIR/kernel/kernel.release"))"
inject_modules "$ROOTFS_DIR"

# -F (space fixup): required for images written by flash tools, which don't
# erase-then-skip empty pages the way UBIFS expects.
mkfs.ubifs -F -x zlib \
    -m "$NAND_PAGE_SIZE" -e "$NAND_LEB_SIZE" -c "$NAND_ROOTFS_MAX_LEBS" \
    -r "$ROOTFS_DIR" "$WORK/rootfs.ubifs"

cat > "$WORK/ubinize.cfg" <<EOF
[rootfs]
mode=ubi
image=$WORK/rootfs.ubifs
vol_id=0
vol_type=dynamic
vol_name=rootfs
vol_flags=autoresize
EOF
ubinize -o "$WORK/pack/rootfs.img" \
    -m "$NAND_PAGE_SIZE" -p "$NAND_PEB_SIZE" "$WORK/ubinize.cfg"

# --------------------------------------------------------------- update.img
# Same pack flow as the SDK's 90-updateimg.sh: afptool + rkImageMaker, chip
# tag read out of the loader binary itself (offset 21, reversed).
log "packing update.img"
cd "$WORK/pack"
cp "$ROOT/board/nand/parameter.txt" parameter.txt
cp "$LOADER" MiniLoaderAll.bin
cp "$UBOOT/uboot.img" uboot.img

cat > package-file <<'EOF'
# NAME	PATH
package-file	package-file
parameter	parameter.txt
bootloader	MiniLoaderAll.bin
uboot	uboot.img
boot	boot.img
rootfs	rootfs.img
EOF

TAG="RK$(dd if=MiniLoaderAll.bin bs=1 skip=21 count=4 status=none | rev)"
log "chip tag: $TAG"
"$PACK_TOOLS/afptool" -pack ./ update.raw.img
"$PACK_TOOLS/rkImageMaker" "-$TAG" MiniLoaderAll.bin update.raw.img update.img -os_type:androidos

cp update.img "$IMAGES/lyra-debian-nand-update.img"

log "done:"
ls -lh "$IMAGES/lyra-debian-nand-update.img" "$WORK/pack"/{boot.img,rootfs.img,uboot.img}
log "flash: hold BOOT, plug USB, then RKDevTool 'Upgrade' or: upgrade_tool uf lyra-debian-nand-update.img"
