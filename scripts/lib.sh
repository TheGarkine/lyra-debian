# Shared setup for all stage scripts. Source, don't execute.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../board.conf
source "$ROOT/board.conf"

SRC_DIR="$ROOT/cache/src"
BUILD_DIR="$ROOT/cache/build"
OUT_DIR="$ROOT/out"
# Container-local scratch (NOT the bind mount): macOS mounts can't faithfully
# hold a rootfs tree (root ownership, device nodes, some symlinks/perms).
# Anything that must round-trip exactly lives here and leaves as a tarball/img.
SCRATCH="/scratch"

mkdir -p "$SRC_DIR" "$BUILD_DIR" "$OUT_DIR" "$SCRATCH"

NPROC="$(nproc)"

log() { printf '\n\033[1;34m[%s]\033[0m %s\n' "$(basename "$0")" "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Inject the kernel modules (from 03-kernel.sh) into an extracted rootfs tree
# and run depmod. This happens at image-assembly time, NOT in the rootfs stage,
# so the rootfs tarball stays kernel-independent — after a kernel change,
# rebuilding the image (make sd / make nand) is enough. Getting this wrong
# shows up as "modprobe: module X not found" for builtins on the device
# (stale modules.builtin).
inject_modules() {
    local rootdir="$1"
    local kver tmp
    kver="$(cat "$OUT_DIR/kernel/kernel.release")"
    tmp="$(mktemp -d)"
    tar -xzf "$OUT_DIR/kernel/modules.tar.gz" -C "$tmp"
    # Copy into usr/lib explicitly — extracting "lib/..." straight into a
    # merged-usr root can replace the /lib symlink with a real directory.
    rm -rf "$rootdir/usr/lib/modules"
    mkdir -p "$rootdir/usr/lib/modules"
    cp -a "$tmp"/lib/modules/. "$rootdir/usr/lib/modules/"
    depmod -b "$rootdir" "$kver"
    rm -rf "$tmp"
}

# All stages assume the Docker builder environment (see build.sh).
[ -f /.dockerenv ] || [ -n "${LYRA_IN_CONTAINER:-}" ] || \
    die "run stages via ./build.sh or make (they need the builder container)"
