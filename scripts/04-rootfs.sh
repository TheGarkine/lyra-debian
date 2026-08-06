#!/usr/bin/env bash
# Build the Debian rootfs with mmdebstrap -> out/rootfs/<variant>/ (directory)
# + lyra-rootfs-<variant>.tar.gz. Variant: sd (default, base+dev tools) or
# nand (base only — must stay well under the ~209 MiB UBIFS budget).
source "$(dirname "$0")/lib.sh"

VARIANT="${1:-sd}"
case "$VARIANT" in sd|nand) ;; *) die "usage: $0 [sd|nand]" ;; esac

# Build in container-local scratch — a rootfs tree can't live on the macOS
# bind mount (ownership/perm/device-node fidelity). Only the tarball goes out.
TARGET="$SCRATCH/rootfs-$VARIANT"
APT_CACHE="$ROOT/cache/apt"
mkdir -p "$APT_CACHE" "$OUT_DIR/rootfs"
rm -rf "$TARGET"

log "checking armhf binfmt/qemu support"
# build.sh installs the handler via tonistiigi/binfmt before starting us.
# Don't try to register qemu from inside this container as a fallback — that
# pins a container-arch interpreter the kernel can't nest under Rosetta/qemu.
arch-test armhf >/dev/null 2>&1 || \
    die "cannot execute armhf binaries. Run on the host: docker run --privileged --rm tonistiigi/binfmt --install arm (build.sh does this automatically)"

PKGS="$PKGS_BASE"
[ "$VARIANT" = sd ] && PKGS="$PKGS,$PKGS_DEV"

# NAND must fit a ~209 MiB UBIFS: drop docs/manpages/translations at the dpkg
# level (survives future apt operations on-device, too). Copyright files are
# kept. The SD variant stays full Debian.
TRIM_OPTS=()
if [ "$VARIANT" = nand ]; then
    TRIM_OPTS=(
        --dpkgopt='path-exclude=/usr/share/doc/*'
        --dpkgopt='path-include=/usr/share/doc/*/copyright'
        --dpkgopt='path-exclude=/usr/share/man/*'
        --dpkgopt='path-exclude=/usr/share/info/*'
        --dpkgopt='path-exclude=/usr/share/locale/*'
        --dpkgopt='path-exclude=/usr/share/lintian/*'
        --dpkgopt='path-exclude=/usr/share/bash-completion/*'
    )
fi

log "running mmdebstrap ($DEBIAN_SUITE armhf, variant=$VARIANT)"
mmdebstrap \
    --architectures=armhf \
    --variant=minbase \
    --include="$PKGS" \
    "${TRIM_OPTS[@]}" \
    --aptopt='APT::Install-Recommends "false"' \
    --aptopt='Acquire::GzipIndexes "true"' \
    --aptopt='Acquire::Languages "none"' \
    --skip=cleanup/apt/lists \
    --setup-hook='mkdir -p "$1"/var/cache/apt/archives' \
    --setup-hook="sync-in $APT_CACHE /var/cache/apt/archives" \
    --customize-hook="sync-out /var/cache/apt/archives $APT_CACHE" \
    --customize-hook="$ROOT/scripts/rootfs-customize.sh \"\$1\" $VARIANT" \
    "$DEBIAN_SUITE" \
    "$TARGET" \
    "deb $DEBIAN_MIRROR $DEBIAN_SUITE $DEBIAN_COMPONENTS" \
    "deb $DEBIAN_MIRROR $DEBIAN_SUITE-updates $DEBIAN_COMPONENTS" \
    "deb $DEBIAN_SECURITY_MIRROR $DEBIAN_SUITE-security $DEBIAN_COMPONENTS"

# Post-build fixups on the output tree (safe from mmdebstrap's own cleanup):
# resolved-managed resolv.conf, and a fresh machine-id per device.
ln -sf ../run/systemd/resolve/stub-resolv.conf "$TARGET/etc/resolv.conf"
: > "$TARGET/etc/machine-id"

# Package manifest: exact Debian package versions in the image. Publish this
# next to released images — it's the pointer for GPL source availability
# (all packages are unmodified Debian; sources at snapshot.debian.org).
dpkg-query --admindir="$TARGET/var/lib/dpkg" -W -f '${Package} ${Version}\n' \
    > "$OUT_DIR/rootfs/lyra-rootfs-$VARIANT-packages.txt"

log "packaging rootfs tarball (the canonical artifact — 05-image-sd re-extracts it)"
tar --numeric-owner -C "$TARGET" -czf "$OUT_DIR/rootfs/lyra-rootfs-$VARIANT.tar.gz" .

log "done — rootfs size: $(du -sh "$TARGET" | cut -f1)"
ls -lh "$OUT_DIR/rootfs/lyra-rootfs-$VARIANT.tar.gz"
