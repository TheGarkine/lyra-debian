#!/usr/bin/env bash
# Build vendor U-Boot in two variants:
#   sd   -> out/u-boot/{u-boot.itb, idbloader.img, *loader*.bin}
#           RKIMG_BOOTCOMMAND patched to load zImage+dtb from the FAT partition.
#   nand -> out/u-boot-nand/{uboot.img, ...}
#           Vendor default bootcmd (boot_fit) — boots the FIT boot.img from the
#           rkparm "boot" partition, which is exactly the NAND flow.
# Faithful transcription of the Yocto recipe u-boot-rk3506_1.0.bb (KCFLAGS,
# make.sh neutering, boot_merger for the new-IDB idbloader).
source "$(dirname "$0")/lib.sh"

S="$SRC_DIR/u-boot"
[ -d "$S/.git" ] || die "u-boot source missing — run 01-fetch.sh first"

# Vendor tree predates current GCC — same -Wno-error list as the Yocto recipe.
KCFLAGS="-Wno-error=maybe-uninitialized -Wno-error=address -Wno-error=enum-int-mismatch -Wno-error=dangling-pointer -Wno-error=array-parameter -Wno-error=stringop-overread"

build_uboot() {           # build_uboot <variant: sd|nand>
    local variant="$1"
    local B="$BUILD_DIR/u-boot-$variant"
    local DEPLOY="$OUT_DIR/u-boot${variant/#sd/}"   # sd -> out/u-boot, nand -> out/u-boot-nand
    [ "$variant" = nand ] && DEPLOY="$OUT_DIR/u-boot-nand"
    mkdir -p "$DEPLOY"

    log "[$variant] preparing build tree (fresh copy of pristine checkout)"
    rm -rf "$B"
    mkdir -p "$B"
    cp -a "$S/." "$B/"
    rm -rf "$B/.git"

    # Vendor make.sh's packing helpers expect an SDK-sibling ../rkbin.
    rm -rf "$BUILD_DIR/rkbin"
    ln -sfn "$SRC_DIR/rkbin" "$BUILD_DIR/rkbin"

    cd "$B"

    if [ "$variant" = sd ]; then
        log "[sd] patching RKIMG_BOOTCOMMAND (load dtb+zImage from mmc 0:1, bootz)"
        python3 "$ROOT/board/uboot/patch-bootcmd.py" "$B/include/configs/rk3506_common.h"
    else
        log "[nand] keeping vendor bootcmd (boot_fit from the rkparm boot partition)"
    fi

    # Neutralise make.sh's SDK toolchain selection; force our cross prefix.
    if [ -f make.sh ]; then
        sed -i -e "/^process_args/a\\TOOLCHAIN=${CROSS_COMPILE}" \
               -e 's/^[[:space:]]*select_toolchain\b.*/: # select_toolchain disabled/' \
               -e 's/^[[:space:]]*select_tool\b.*/: # select_tool disabled/' \
               make.sh
    fi

    local MAKE=(make CROSS_COMPILE="$CROSS_COMPILE" HOSTCC=gcc PYTHON=python3 KCFLAGS="$KCFLAGS")

    log "[$variant] configuring (rk3506_defconfig + lyra-uboot.cfg)"
    "${MAKE[@]}" rk3506_defconfig
    cat "$ROOT/board/uboot/lyra-uboot.cfg" >> .config
    "${MAKE[@]}" olddefconfig

    log "[$variant] building U-Boot"
    "${MAKE[@]}" -j"$NPROC" all

    # make.sh's packing helpers run their own make/python: cc->gcc shim + env.
    mkdir -p .hostbin
    ln -sf "$(command -v gcc)" .hostbin/cc
    export PATH="$B/.hostbin:$PATH"
    export CROSS_COMPILE TOOLCHAIN="$CROSS_COMPILE" PYTHON=python3
    # macOS bind mounts can drop exec bits — restore them on the SDK helpers.
    chmod +x make.sh scripts/*.sh scripts/*.py tools/* 2>/dev/null || true

    log "[$variant] packing u-boot.itb (FIT; SPL loads it)"
    ./make.sh itb

    if [ "$variant" = nand ]; then
        # uboot.img: the FIT padded/duplicated for the rkparm "uboot" partition
        # (SPL scans it there on NAND). make.sh's uboot pack produces it.
        log "[nand] packing uboot.img"
        ./make.sh uboot || true
        if [ ! -f uboot.img ]; then
            log "[nand] make.sh uboot produced no uboot.img — using u-boot.itb as-is"
            cp u-boot.itb uboot.img
        fi
        cp uboot.img "$DEPLOY/"
    fi

    # idbloader.img: RK3506 needs Rockchip's *new IDB* format. mkimage -T rksd
    # produces the old format — the maskrom runs the DDR blob but never the SPL
    # (silent brick). boot_merger + the chip INI is the only correct path.
    log "[$variant] packing idbloader.img + maskrom loader via boot_merger ($RK3506_LOADER_INI)"
    local RKBINW="$BUILD_DIR/rkbin-work"
    rm -rf "$RKBINW"
    cp -rL "$SRC_DIR/rkbin" "$RKBINW"
    rm -rf "$RKBINW/.git"
    chmod -R u+w "$RKBINW"
    chmod +x "$RKBINW"/tools/* 2>/dev/null || true
    ( cd "$RKBINW" && ./tools/boot_merger "$RK3506_LOADER_INI" )

    cp "$RKBINW"/*idblock*.img "$DEPLOY/idbloader.img"
    # The full loader (DDR+usbplug) for maskrom-mode flashing — this is the
    # "MiniLoaderAll.bin" that RKDevTool/upgrade_tool and update.img need.
    cp "$RKBINW"/rk3506*loader*.bin "$DEPLOY/" 2>/dev/null || \
        cp "$RKBINW"/*[Ll]oader*.bin "$DEPLOY/" 2>/dev/null || \
        log "WARNING: no maskrom loader .bin found in boot_merger output"
    cp "$B/u-boot.itb" "$DEPLOY/"

    log "[$variant] sanity checks"
    head -c 4 "$DEPLOY/idbloader.img" | grep -q RKNS || \
        die "idbloader.img lacks RKNS magic — wrong IDB format, would not boot"

    log "[$variant] done:"
    ls -lh "$DEPLOY"
}

build_uboot sd
build_uboot nand
