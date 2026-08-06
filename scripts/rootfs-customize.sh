#!/usr/bin/env bash
# mmdebstrap customize hook: called with the chroot dir + variant.
set -euo pipefail

CHROOT="$1"
VARIANT="$2"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/board.conf"

echo "[customize] overlay"
rsync -a "$ROOT/overlay/" "$CHROOT/"
[ "$VARIANT" = sd ] && rsync -a "$ROOT/overlay-sd/" "$CHROOT/"

# NB: kernel modules are deliberately NOT installed here — the image stages
# (05/06) inject them via inject_modules(), keeping this rootfs kernel-agnostic.

echo "[customize] identity"
echo "$HOSTNAME" > "$CHROOT/etc/hostname"
cat > "$CHROOT/etc/hosts" <<EOF
127.0.0.1	localhost
127.0.1.1	$HOSTNAME
::1		localhost ip6-localhost ip6-loopback
EOF

echo "[customize] users ($USER_NAME with sudo; root login disabled)"
chroot "$CHROOT" useradd -m -s /bin/bash "$USER_NAME"
echo "$USER_NAME:$USER_PASSWORD" | chroot "$CHROOT" chpasswd
# systemd-journal: read the full journal without relying on journald's
# per-user ACLs (UBIFS on the NAND image doesn't support ACLs at all).
chroot "$CHROOT" usermod -aG sudo,adm,dialout,plugdev,audio,video,systemd-journal "$USER_NAME"
chroot "$CHROOT" passwd -l root
# sudoers.d files must be root:root and not group/world-writable; validate.
chmod 440 "$CHROOT/etc/sudoers.d/010-lyra-nopasswd"
chroot "$CHROOT" visudo -c

echo "[customize] services"
UNITS=(systemd-networkd.service systemd-timesyncd.service usb-gadget.service
       serial-getty@ttyFIQ0.service ssh.service)
[ "$VARIANT" = sd ] && UNITS+=(firstboot-resize.service)
chroot "$CHROOT" systemctl enable "${UNITS[@]}"

# NAND variant mounts a UBIFS root, not the SD partitions.
if [ "$VARIANT" = nand ]; then
    sed -i 's/^PARTLABEL/#PARTLABEL/' "$CHROOT/etc/fstab"
    # udev's hardware database (~20 MB) classifies USB/PCI/input devices —
    # nothing on this headless board needs it, and NAND space is precious.
    rm -rf "$CHROOT/usr/lib/udev/hwdb.d" "$CHROOT/etc/udev/hwdb.bin" \
           "$CHROOT/usr/lib/udev/hwdb.bin"
fi

echo "[customize] apt test"
chroot "$CHROOT" apt-get update
chroot "$CHROOT" apt-get clean

echo "[customize] done"
