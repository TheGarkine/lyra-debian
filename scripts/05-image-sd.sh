#!/usr/bin/env bash
# Assemble the SD/eMMC GPT image — loopless (no loop devices, container-safe):
# ext4 via mke2fs -d, FAT via mkfs.vfat+mcopy, partition table via sfdisk on a
# sparse file, raw pieces dd'ed in.
#
# Layout (512-byte sectors — proven by the Yocto wic build):
#   64     idbloader.img  (DDR init + SPL, Rockchip new-IDB format)
#   16384  u-boot.itb     (FIT, must be < 8 MiB — SPL reads sector 0x4000)
#   32768  GPT part 1 "boot"  FAT32 64 MiB   zImage + dtb
#   163840 GPT part 2 "root"  ext4, rest     Debian rootfs
source "$(dirname "$0")/lib.sh"

UBOOT="$OUT_DIR/u-boot"
KERNEL="$OUT_DIR/kernel"
ROOTFS_TAR="$OUT_DIR/rootfs/lyra-rootfs-sd.tar.gz"
IMAGES="$OUT_DIR/images"
IMG="$IMAGES/lyra-debian-sd.img"
WORK="$SCRATCH/image-sd"     # container-local: fast, and mkfs inputs need fidelity

for f in "$UBOOT/idbloader.img" "$UBOOT/u-boot.itb" "$KERNEL/zImage" "$KERNEL/$DTB_NAME"; do
    [ -f "$f" ] || die "missing artifact: $f (run earlier stages)"
done
[ -f "$ROOTFS_TAR" ] || die "missing rootfs tarball: $ROOTFS_TAR (run 04-rootfs.sh sd)"

mkdir -p "$IMAGES" "$WORK"

log "extracting rootfs tarball into scratch (bind mounts can't hold a rootfs tree)"
ROOTFS="$WORK/rootfs"
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"
tar --numeric-owner -xzf "$ROOTFS_TAR" -C "$ROOTFS"

log "injecting kernel modules ($(cat "$OUT_DIR/kernel/kernel.release"))"
inject_modules "$ROOTFS"

BOOT_SECTORS=$((BOOT_PART_MB * 2048))
if [ -n "${SD_IMAGE_MB:-}" ]; then
    TOTAL_SECTORS=$((SD_IMAGE_MB * 2048))
    ROOT_SECTORS=$((TOTAL_SECTORS - SECTOR_ROOT - 34))   # 33 backup-GPT sectors
else
    # Auto-size: rootfs content + headroom (first boot grows it to the card).
    ROOTFS_MB=$(du -sm --apparent-size "$ROOTFS" | cut -f1)
    ROOT_SECTORS=$(( (ROOTFS_MB + ROOTFS_HEADROOM_MB) * 2048 ))
    TOTAL_SECTORS=$((SECTOR_ROOT + ROOT_SECTORS + 34))
    log "auto-sized image: ${ROOTFS_MB} MiB rootfs + ${ROOTFS_HEADROOM_MB} MiB headroom"
fi

log "building boot partition (FAT32, zImage + $DTB_NAME)"
BOOTFS="$WORK/boot.vfat"
rm -f "$BOOTFS"
truncate -s $((BOOT_SECTORS * 512)) "$BOOTFS"
mkfs.vfat -F 32 -n BOOT "$BOOTFS" > /dev/null
mcopy -i "$BOOTFS" "$KERNEL/zImage" ::zImage
mcopy -i "$BOOTFS" "$KERNEL/$DTB_NAME" "::$DTB_NAME"

log "building root partition (ext4, label root, $((ROOT_SECTORS / 2048)) MiB)"
ROOTIMG="$WORK/rootfs.ext4"
rm -f "$ROOTIMG"
mke2fs -q -F -t ext4 -b 4096 -L root -d "$ROOTFS" \
    -E root_owner=0:0,lazy_itable_init=0 \
    "$ROOTIMG" $((ROOT_SECTORS * 512 / 4096))

log "writing GPT + raw pieces into $(basename "$IMG")"
rm -f "$IMG"
truncate -s $((TOTAL_SECTORS * 512)) "$IMG"
sfdisk -q "$IMG" <<EOF
label: gpt
unit: sectors
start=$SECTOR_BOOT, size=$BOOT_SECTORS, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="boot", bootable
start=$SECTOR_ROOT, size=$ROOT_SECTORS, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="root"
EOF

UBOOT_SIZE=$(stat -c %s "$UBOOT/u-boot.itb")
[ "$UBOOT_SIZE" -lt $(( (SECTOR_BOOT - SECTOR_UBOOT) * 512 )) ] || \
    die "u-boot.itb ($UBOOT_SIZE bytes) overflows its 8 MiB slot"

dd if="$UBOOT/idbloader.img" of="$IMG" bs=512 seek="$SECTOR_IDBLOADER" conv=notrunc status=none
dd if="$UBOOT/u-boot.itb"    of="$IMG" bs=512 seek="$SECTOR_UBOOT"     conv=notrunc status=none
dd if="$BOOTFS"              of="$IMG" bs=512 seek="$SECTOR_BOOT"      conv=notrunc status=none
dd if="$ROOTIMG"             of="$IMG" bs=512 seek="$SECTOR_ROOT"      conv=notrunc status=none

log "verifying"
sfdisk --verify "$IMG"
sfdisk --dump "$IMG"

bmaptool create "$IMG" > "$IMG.bmap" 2>/dev/null || true

log "done:"
ls -lh "$IMAGES"
log "flash with: make flash-sd DEV=/dev/rdiskN   (macOS; diskutil list to find N)"
