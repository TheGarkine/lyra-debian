# lyra-debian — Debian 13 (trixie) for the Luckfox Lyra Plus

Builds a **modern Debian armhf image** for the **Luckfox Lyra Plus** (Rockchip
RK3506G2, triple Cortex-A7, 128 MB RAM) with **working `deb.debian.org` mirrors**
— `apt update && apt install` just works on the device. Runs entirely in Docker,
so it builds on macOS (Docker Desktop / OrbStack) or any Linux box.

The board support (DTS, kernel config fragments, U-Boot boot command, SD
layout) was originally proven with a Yocto BSP for the same board and is
carried here in `board/` — only the rootfs differs: real Debian via
`mmdebstrap` instead of a Yocto-built image.

## What you get (`out/` after `make all`)

| Artifact | Purpose |
|---|---|
| `images/lyra-debian-sd.img` (+`.bmap`) | Flashable microSD image (GPT). Also usable for eMMC-equipped Lyra variants via Rockchip loader mode. |
| `u-boot/idbloader.img`, `u-boot/u-boot.itb` | Raw boot pieces (DDR+SPL loader, U-Boot FIT) |
| `u-boot/*loader*.bin` | Maskrom-mode loader for RKDevTool/upgrade_tool (eMMC/NAND flashing) |
| `kernel/zImage`, `kernel/*.dtb`, `kernel/modules.tar.gz` | Vendor 6.1 kernel pieces |
| `rootfs/lyra-rootfs-{sd,nand}.tar.gz` | The rootfs as tarballs |
| `images/lyra-debian-nand-update.img` | **SPI NAND firmware** (`make nand`, experimental) for RKDevTool/upgrade_tool |
| `manifest.txt` | Resolved git SHAs of kernel/U-Boot/rkbin for this build |

## SPI NAND (`make nand`, experimental until verified on hardware)

Builds a Rockchip `update.img`: vendor-bootcmd U-Boot (`boot_fit`), FIT
`boot.img` (zImage + NAND DTB with UBIFS-root bootargs + resource), and a
UBI/UBIFS rootfs (trimmed variant: no docs/locales/hwdb, ~133 MB tree →
~50 MB UBI image on the ~209 MiB partition). Partition map
(`board/nand/parameter.txt`, from the Luckfox SDK): uboot 4 MiB@4 MiB, boot
12 MiB@8 MiB, rootfs grows from 32 MiB; first 4 MiB = idblock loader.

Flash: hold **BOOT** while plugging USB (no SD card inserted), then
`make flash-nand` (uses `tools/upgrade_tool` — fetch it once with
`make get-upgrade-tool`; RKDevTool on Windows works too). The boot ROM prefers
NAND over SD — once NAND is flashed the board boots NAND; `make erase-nand`
wipes it to return to SD boot. The SD-booted system also sees the NAND as `/dev/mtd*` (fspi node in the
shared DTS), handy for inspection.

## Build

Requires Docker (tested with Rancher Desktop on macOS; Docker Desktop/OrbStack
work the same — `build.sh` installs the armhf qemu binfmt handler into the
Docker VM automatically via `tonistiigi/binfmt`). Then:

```sh
make all          # fetch + u-boot + kernel + rootfs + SD image
```

or stage by stage: `make fetch`, `make uboot`, `make kernel`, `make rootfs`,
`make sd`. `make shell` drops you into the builder container. Sources are
cached in `cache/`, artifacts land in `out/` (both gitignored).

All knobs live in **`board.conf`**: mirrors, Debian suite, hostname, the
default user account, package lists, image size, source pins.
After the first verified boot, paste the SHAs from `out/manifest.txt` into
`KERNEL_REF` / `RKBIN_REF` to pin the build.

## Flash & first boot

```sh
diskutil list                      # find your SD card, e.g. /dev/disk4
make flash-sd DEV=/dev/rdisk4
```

- **Serial console**: UART0 at **1500000 baud** 8N1 (not every USB-serial dongle
  can do 1.5 Mbaud — CP2102N and FT232H are known good):
  `screen /dev/tty.usbserial-XXXX 1500000`
- **Login: `lyra` / `lyra`** (serial and SSH; change it on first boot with
  `passwd`, or in `board.conf` before building). The account is a full sudoer
  (`sudo -i` for a root shell). **Root login is disabled** — the root password
  is locked and sshd has `PermitRootLogin no`.
- **apt is ready to use**: the package lists were refreshed at image build
  time (and stored compressed), so `sudo apt install <pkg>` works immediately;
  run `sudo apt update` whenever you want newer lists. `htop` is preinstalled
  in both images.
- **Ethernet**: DHCP via systemd-networkd → `ssh lyra@<ip>`.
- **USB gadget** (USB-C/OTG0 port): board appears as a USB network adapter
  (CDC-ECM + ACM serial). Board is `10.42.0.1`, your host gets an address via
  DHCP → `ssh lyra@10.42.0.1`.
- Root partition grows to fill the card on first boot; time syncs via NTP
  (`fake-hwclock` bridges the missing RTC until then); zram swap is active
  (128 MB RAM!).
- SSH host keys are baked at build time — regenerate on the device if you flash
  more than one board (`rm /etc/ssh/ssh_host_* && ssh-keygen -A && systemctl restart ssh`).

Expected boot chain on serial: DDR banner → SPL → U-Boot (`Hit key to stop
autoboot`) → `bootz` → kernel earlycon → systemd → `lyra login:`.

## How it works

```
board.conf                  all configuration
docker/Dockerfile           debian:trixie builder (cross-gcc, mmdebstrap, qemu, mtools…)
build.sh                    docker build + run --privileged (default --platform linux/amd64:
                            fast via Rosetta on Apple Silicon, and the prebuilt Rockchip
                            host tools are x86_64-only)
scripts/01-fetch.sh         shallow-clone kernel (develop-6.1) / U-Boot (pinned) / rkbin
scripts/02-uboot.sh         rk3506_defconfig, patch RKIMG_BOOTCOMMAND (load zImage+dtb
                            from FAT, bootz), make all + make.sh itb → u-boot.itb;
                            boot_merger RK3506MINIALL.ini → idbloader.img (new-IDB format —
                            never mkimage -T rksd, that silently fails to boot)
scripts/03-kernel.sh        rk3506_defconfig + rk3506-ethernet.config + rk3506-lyra.cfg,
                            board DTS injected → zImage/dtb/modules
scripts/04-rootfs.sh        mmdebstrap trixie armhf minbase (+ overlay/, modules,
                            services, apt smoke test) under qemu binfmt
scripts/05-image-sd.sh      loopless GPT assembly: idbloader@64s, u-boot.itb@16384s,
                            FAT32 boot@32768s (64 MiB), ext4 root@163840s
board/                      board DTS + kernel/U-Boot fragments (from the Yocto layer)
overlay/, overlay-sd/       files rsynced into the rootfs (networkd DHCP, usb-gadget
                            configfs service, sshd drop-in, fstab, zram, firstboot-resize)
```

## Releasing

For a new release: add a section at the **top** of `RELEASE_NOTES.md` (heading
must contain the version, e.g. `# v0.2.0 — …`), separated from older notes by
a `-----` line, commit, then run `make github-release`. It extracts that top
section, runs `make release`, tags, pushes, and publishes a GitHub release
with the artifacts attached and only the newest notes as the release text
(needs the `gh` CLI, authenticated).

Under the hood, `make release` collects everything worth publishing into `out/release/`:
`lyra-debian-sd.img.xz` (+ `.bmap`), `lyra-debian-nand-update.img`,
`manifest.txt` (exact kernel/U-Boot/rkbin git SHAs) and the Debian package
lists. Upload those as release assets. Do **not** commit or upload `tools/`
(proprietary Rockchip flashing tools — users fetch their own copy via
`make get-upgrade-tool`).

## Licensing

The **build system in this repo is MIT** (see LICENSE); the board DTS files in
`board/` are GPL-2.0+ OR MIT (derived from the Rockchip vendor kernel).

The **built images** additionally contain:

| Component | License | Source / notes |
|---|---|---|
| Debian rootfs | DFSG-free (GPL, BSD, …) | Unmodified packages from `main`; exact versions in the released `*-packages.txt`, sources at [snapshot.debian.org](https://snapshot.debian.org) |
| Linux kernel | GPL-2.0 | [rockchip-linux/kernel](https://github.com/rockchip-linux/kernel), commit pinned in released `manifest.txt`; our additions (DTS, config fragment) are in this repo |
| U-Boot | GPL-2.0+ | [rockchip-linux/u-boot](https://github.com/rockchip-linux/u-boot), pinned commit in `manifest.txt`; our bootcmd patch is `board/uboot/patch-bootcmd.py` |
| Rockchip loader blobs (DDR init, SPL, TEE — inside `idbloader.img`, the loader `.bin` and `update.img`) | Rockchip proprietary | [rockchip-linux/rkbin](https://github.com/rockchip-linux/rkbin) — its LICENSE **explicitly permits copying and distribution** (conditions: keep notices, no reverse engineering) |

This satisfies the GPL source-availability requirement the usual way for
unmodified-distro images: the released manifest + package lists identify every
binary exactly, and all corresponding sources are publicly archived at the
linked locations (plus this repo for our own patches).

## Sources / credits

- Vendor sources: [rockchip-linux/kernel](https://github.com/rockchip-linux/kernel/tree/develop-6.1) ·
  [rockchip-linux/u-boot](https://github.com/rockchip-linux/u-boot/tree/next-dev) ·
  [rockchip-linux/rkbin](https://github.com/rockchip-linux/rkbin)
- Prior art for Debian/Ubuntu on RK3506: [sunslayr/PicoCalc-Lyra](https://github.com/sunslayr/PicoCalc-Lyra)
  (debootstrap approach) · [markbirss/rk3506-ubuntu](https://github.com/markbirss/rk3506-ubuntu)
- [Luckfox Lyra wiki](https://wiki.luckfox.com/Luckfox-Lyra/) —
  [SDK image compilation](https://wiki.luckfox.com/Luckfox-Lyra/SDK-Image-Compilation/) ·
  [image flashing](https://wiki.luckfox.com/Luckfox-Lyra/Getting-Started/Image-flashing/)
  (NAND/eMMC loader-mode flashing, RKDevTool/upgrade_tool)
