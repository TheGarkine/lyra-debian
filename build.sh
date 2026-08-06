#!/usr/bin/env bash
# Entry point: build the builder image, then run a command inside it.
#   ./build.sh                      -> interactive shell
#   ./build.sh scripts/02-uboot.sh  -> run one stage (what the Makefile does)
#
# Default platform is linux/amd64 even on Apple Silicon: Docker Desktop/OrbStack
# run it fast via Rosetta, and the prebuilt Rockchip host tools (boot_merger,
# afptool, ...) are x86_64-only. Override with LYRA_PLATFORM=linux/arm64 on a
# native arm64 Linux host if you accept running those tools under qemu-x86_64.
set -euo pipefail
cd "$(dirname "$0")"

PLATFORM="${LYRA_PLATFORM:-linux/amd64}"
IMAGE=lyra-debian-builder

docker build --platform "$PLATFORM" -t "$IMAGE" docker

# Ensure the Docker VM kernel can exec armhf binaries (needed for the mmdebstrap
# chroot). tonistiigi/binfmt registers a HOST-native static qemu-arm with the
# fix-binary flag — the only variant that works from inside our container.
# (Do NOT register qemu via update-binfmts inside the container instead: that
# pins a container-arch interpreter, which the kernel refuses to nest under
# Rosetta/qemu on arm64 VMs.) Idempotent, ~1s.
docker run --privileged --rm tonistiigi/binfmt --install arm >/dev/null 2>&1 || \
    echo "WARNING: binfmt install failed — armhf rootfs stage may not work" >&2

# (plain string, not an array: macOS bash 3.2 chokes on empty arrays with set -u)
TTY_ARGS=""
[ -t 0 ] && TTY_ARGS="-it"

# --privileged: mmdebstrap needs mount/mknod/chroot, and we may have to register
# qemu-arm binfmt handlers at runtime (Docker Desktop/OrbStack usually preinstall
# them, 04-rootfs.sh verifies with arch-test).
# shellcheck disable=SC2086
exec docker run --rm $TTY_ARGS --privileged --platform "$PLATFORM" \
    -v "$PWD":/work -w /work \
    -e DEBIAN_FRONTEND=noninteractive \
    "$IMAGE" "${@:-bash}"
