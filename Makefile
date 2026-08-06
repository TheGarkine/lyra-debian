# lyra-debian — Debian 13 (trixie) armhf image builder for the Luckfox Lyra Plus.
# Every build target runs inside the Docker builder (see build.sh); flash-sd
# runs on the macOS/Linux host.

.PHONY: all fetch uboot kernel rootfs rootfs-nand sd nand shell clean distclean flash-sd flash-nand erase-nand release github-release get-upgrade-tool

all: fetch uboot kernel rootfs sd

fetch:
	./build.sh scripts/01-fetch.sh

uboot:
	./build.sh scripts/02-uboot.sh

kernel:
	./build.sh scripts/03-kernel.sh

rootfs:
	./build.sh scripts/04-rootfs.sh sd

rootfs-nand:
	./build.sh scripts/04-rootfs.sh nand

sd:
	./build.sh scripts/05-image-sd.sh

nand: rootfs-nand
	./build.sh scripts/06-image-nand.sh

shell:
	./build.sh

clean:
	rm -rf out

distclean: clean
	rm -rf cache

# Collect release artifacts into out/release/: xz-compressed SD image + bmap,
# NAND update.img, source manifest and Debian package lists.
release:
	@test -f out/images/lyra-debian-sd.img || { echo "SD image missing — run 'make all' first"; exit 1; }
	@test -f out/images/lyra-debian-nand-update.img || { echo "NAND image missing — run 'make nand' first (releases must contain BOTH images)"; exit 1; }
	mkdir -p out/release
	xz -T0 -6 -kc out/images/lyra-debian-sd.img > out/release/lyra-debian-sd.img.xz
	cp out/images/lyra-debian-sd.img.bmap out/release/
	cp out/images/lyra-debian-nand-update.img out/release/
	cp out/manifest.txt out/rootfs/lyra-rootfs-*-packages.txt out/release/
	@echo; echo "Upload the contents of out/release/ as release assets:"; ls -lh out/release

# Tag + publish a GitHub release with out/release/* attached, using the TOP
# section of RELEASE_NOTES.md (above the first ----- line) as release notes.
github-release:
	scripts/github-release.sh

# Fetch the proprietary macOS upgrade_tool from the Luckfox wiki into tools/
# (gitignored — it is not redistributable under a clear license, so every
# user downloads their own copy).
get-upgrade-tool:
	mkdir -p tools /tmp/lyra-ut
	curl -sL -o /tmp/lyra-ut/ut.zip "https://wiki.luckfox.com/assets/files/upgrade_tool_v2.44_for_mac-d34c9648a1c9bd0e965d598dc3183b67.zip"
	cd /tmp/lyra-ut && unzip -o ut.zip 'upgrade_tool_v2.44_for_mac/upgrade_tool' 'upgrade_tool_v2.44_for_mac/config.ini'
	cp /tmp/lyra-ut/upgrade_tool_v2.44_for_mac/upgrade_tool /tmp/lyra-ut/upgrade_tool_v2.44_for_mac/config.ini tools/
	chmod +x tools/upgrade_tool
	@echo "installed tools/upgrade_tool (run it from inside tools/ — it crashes elsewhere)"

# Flash the NAND firmware over USB. Board must be in loader/maskrom mode:
# no SD card inserted, hold BOOT while plugging in USB. upgrade_tool must be
# run from inside tools/ — it segfaults from any other directory.
flash-nand:
	@test -x tools/upgrade_tool || { echo "tools/upgrade_tool missing — run 'make get-upgrade-tool'"; exit 1; }
	@test -f out/images/lyra-debian-nand-update.img || { echo "no NAND image — run 'make nand' first"; exit 1; }
	@cd tools && ./upgrade_tool LD | grep -q Mode= || { echo "no board in loader mode found (hold BOOT while plugging USB, no SD card)"; exit 1; }
	@cd tools && ./upgrade_tool LD
	@printf "Flash NAND with lyra-debian-nand-update.img? Type yes to continue: " && read a && [ "$$a" = yes ]
	cd tools && ./upgrade_tool UF ../out/images/lyra-debian-nand-update.img

# Erase the NAND so the board falls back to SD boot (boot ROM prefers NAND).
erase-nand:
	@test -x tools/upgrade_tool || { echo "tools/upgrade_tool missing — run 'make get-upgrade-tool'"; exit 1; }
	@LOADER=$$(ls out/u-boot/rk3506*loader*.bin 2>/dev/null | head -n1); \
	test -n "$$LOADER" || { echo "no loader .bin in out/u-boot — run 'make uboot' first"; exit 1; }; \
	printf "Erase the entire SPI NAND? Type yes to continue: " && read a && [ "$$a" = yes ] && \
	cd tools && ./upgrade_tool EF "../$$LOADER"

# Flash the SD image from the host. macOS: make flash-sd DEV=/dev/rdiskN
# (find N with `diskutil list`; rdisk is much faster than disk).
flash-sd:
	@test -n "$(DEV)" || { echo "usage: make flash-sd DEV=/dev/rdiskN"; exit 1; }
	@test -f out/images/lyra-debian-sd.img || { echo "no image — run 'make all' first"; exit 1; }
	@echo "About to overwrite $(DEV) with out/images/lyra-debian-sd.img:"
	@diskutil info $(DEV) 2>/dev/null | grep -E 'Device Node|Media Name|Disk Size' || true
	@printf "Type yes to continue: " && read a && [ "$$a" = yes ]
	-diskutil unmountDisk $(DEV)
	sudo dd if=out/images/lyra-debian-sd.img of=$(DEV) bs=4m status=progress
	sync
	-diskutil eject $(DEV)
