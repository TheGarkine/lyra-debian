# Build environment for lyra-debian: cross toolchain, mmdebstrap + qemu for the
# armhf rootfs, and everything for loopless image assembly. Run via ../build.sh
# (needs --privileged for the mmdebstrap chroot + binfmt).
FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        # kernel + U-Boot build
        build-essential git make bc bison flex libssl-dev \
        device-tree-compiler u-boot-tools swig \
        python3 python3-dev python3-pyelftools python3-setuptools \
        lz4 lzop cpio kmod ccache \
        # Cross toolchains: armel (soft-float) for U-Boot + kernel
        crossbuild-essential-armel crossbuild-essential-armhf \
        # rootfs (armhf chroot under qemu binfmt)
        mmdebstrap qemu-user-static binfmt-support arch-test \
        debian-archive-keyring \
        # loopless image assembly
        e2fsprogs dosfstools mtools fdisk gdisk util-linux bmap-tools \
        # SPI NAND artifacts (M3)
        mtd-utils \
        # misc
        wget curl rsync xz-utils file ca-certificates procps \
    && rm -rf /var/lib/apt/lists/*

RUN ln -sf bash /bin/sh

WORKDIR /work
CMD ["bash"]
