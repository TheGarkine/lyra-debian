#!/usr/bin/env python3
"""Rewrite RKIMG_BOOTCOMMAND in include/configs/rk3506_common.h.

Rockchip's U-Boot hardcodes bootcmd via this macro (boot_fit;boot_android),
which overrides Kconfig's CONFIG_BOOTCOMMAND. Replace it with our SD flow:
load dtb + zImage from the FAT boot partition (mmc 0:1) and bootz.
"""
import re
import sys

NEW = r'''#undef RKIMG_BOOTCOMMAND
#define RKIMG_BOOTCOMMAND \
	"setenv bootargs earlycon=uart8250,mmio32,0xff0a0000 console=ttyFIQ0,1500000 root=PARTLABEL=root rootfstype=ext4 rootwait rw; " \
	"load mmc 0:1 ${fdt_addr_r} rk3506g-luckfox-lyra-plus.dtb && " \
	"load mmc 0:1 ${kernel_addr_r} zImage && " \
	"bootz ${kernel_addr_r} - ${fdt_addr_r}"
'''

def main():
    path = sys.argv[1]
    with open(path) as f:
        s = f.read()
    if 'bootz ${kernel_addr_r}' in s:
        print(f"patch-bootcmd: {path} already patched")
        return
    # Match the whole "#undef ... #ifdef CONFIG_FIT_SIGNATURE ... #else ... #endif" block.
    s, n = re.subn(r'#undef RKIMG_BOOTCOMMAND\n#ifdef CONFIG_FIT_SIGNATURE.*?\n#endif\n',
                   NEW, s, count=1, flags=re.S)
    assert n == 1, "RKIMG_BOOTCOMMAND block not found in " + path
    with open(path, 'w') as f:
        f.write(s)
    print(f"patch-bootcmd: rewrote RKIMG_BOOTCOMMAND in {path}")

if __name__ == '__main__':
    main()
