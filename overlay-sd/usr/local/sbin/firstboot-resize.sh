#!/bin/sh
# Grow the root partition to fill the SD card, once, on first boot.
set -eu

MARKER=/etc/.firstboot-resize-done
[ -e "$MARKER" ] && exit 0

ROOTPART=$(findmnt -no SOURCE /)          # e.g. /dev/mmcblk0p2
DISK=$(echo "$ROOTPART" | sed 's/p[0-9]*$//')
PARTNUM=$(echo "$ROOTPART" | grep -o '[0-9]*$')

if [ -b "$DISK" ] && [ -n "$PARTNUM" ]; then
    growpart "$DISK" "$PARTNUM" || true    # no-op/fails harmlessly if already full-size
    resize2fs "$ROOTPART"
fi

touch "$MARKER"
