# v0.1.0 — Initial release

**Images** (flash instructions in the README):

- `lyra-debian-sd.img.xz` (+ `.bmap`) — microSD image, also flashable to
  eMMC-equipped Lyra variants via loader mode. Debian 13 (trixie) armhf,
  systemd, SSH, ~570 MB; root partition grows to fill the card on first boot.
- `lyra-debian-nand-update.img` — SPI NAND firmware for RKDevTool /
  `upgrade_tool` (trimmed rootfs, UBIFS).

-----
