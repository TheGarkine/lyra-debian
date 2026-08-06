#!/usr/bin/env bash
# Build the vendor 6.1 kernel -> out/kernel/{zImage, <dtb>, modules.tar.gz}.
# Mirrors the Yocto recipe linux-rk3506_6.1.bb: rk3506_defconfig + vendor
# ethernet fragment + our lyra fragment, board DTS injected into the tree.
source "$(dirname "$0")/lib.sh"

S="$SRC_DIR/kernel"
B="$BUILD_DIR/kernel"
DEPLOY="$OUT_DIR/kernel"
[ -d "$S/.git" ] || die "kernel source missing — run 01-fetch.sh first"
mkdir -p "$B" "$DEPLOY"

MAKE=(make -C "$S" O="$B" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" KCFLAGS=-Wno-error)

log "injecting board DTS files into arch/arm/boot/dts (idempotent)"
for dts in rk3506g-luckfox-lyra-plus rk3506g-luckfox-lyra-plus-nand; do
    install -m 0644 "$ROOT/board/$dts.dts" "$S/arch/arm/boot/dts/"
    if ! grep -q "$dts.dtb" "$S/arch/arm/boot/dts/Makefile"; then
        echo "dtb-\$(CONFIG_ARCH_ROCKCHIP) += $dts.dtb" \
            >> "$S/arch/arm/boot/dts/Makefile"
    fi
done

log "configuring (rk3506_defconfig + rk3506-ethernet.config + rk3506-lyra.cfg)"
"${MAKE[@]}" rk3506_defconfig
# NB: the vendor rk3506-usb-peripheral.config is intentionally NOT merged — it
# pins dwc2 to PERIPHERAL-only, blocking the OTG1 host port. Our fragment
# carries USB_DWC2_DUAL_ROLE instead. No NAND fragment is needed: the vendor
# defconfig already has the full SPI-NAND/MTD/UBI/UBIFS stack built in.
FRAGMENTS=("$S/arch/arm/configs/rk3506-ethernet.config"
           "$ROOT/board/kernel-fragments/rk3506-lyra.cfg")
for frag in "${FRAGMENTS[@]}"; do
    [ -f "$frag" ] || die "missing config fragment: $frag"
    "$S/scripts/kconfig/merge_config.sh" -m -O "$B" "$B/.config" "$frag"
done
"${MAKE[@]}" olddefconfig

log "building zImage + dtbs + modules"
"${MAKE[@]}" -j"$NPROC" zImage dtbs modules

log "packaging modules"
MODSTAGE="$BUILD_DIR/modules-stage"
rm -rf "$MODSTAGE"
# INSTALL_MOD_STRIP: unstripped vendor modules carry ~50 MB of debug symbols.
"${MAKE[@]}" INSTALL_MOD_PATH="$MODSTAGE" INSTALL_MOD_STRIP=1 modules_install
# Strip the build/source symlinks — they'd dangle on the device.
find "$MODSTAGE/lib/modules" -maxdepth 2 -type l -delete
tar -C "$MODSTAGE" -czf "$DEPLOY/modules.tar.gz" lib

cp "$B/arch/arm/boot/zImage" "$DEPLOY/"
cp "$B/arch/arm/boot/dts/$DTB_NAME" "$DEPLOY/"
cp "$B/arch/arm/boot/dts/$DTB_NAME_NAND" "$DEPLOY/"
cp "$B/include/config/kernel.release" "$DEPLOY/kernel.release"

log "done ($(cat "$B/include/config/kernel.release")):"
ls -lh "$DEPLOY"
