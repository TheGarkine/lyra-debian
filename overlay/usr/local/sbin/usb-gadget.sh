#!/bin/sh
# Bring up a USB CDC-ECM (+ ACM serial) Ethernet gadget via configfs. The device
# appears to the USB host as a network adapter on interface usb0.
set -e

G=/sys/kernel/config/usb_gadget/lyra
CFGFS=/sys/kernel/config

grep -qs "${CFGFS} " /proc/mounts || mount -t configfs none "${CFGFS}"

# Already bound? (idempotent on restart)
if [ -s "${G}/UDC" ]; then
    exit 0
fi

mkdir -p "${G}"
echo 0x1d6b > "${G}/idVendor"     # Linux Foundation
echo 0x0104 > "${G}/idProduct"    # Multifunction Composite Gadget
echo 0x0200 > "${G}/bcdUSB"
echo 0x0100 > "${G}/bcdDevice"

mkdir -p "${G}/strings/0x409"
SERIAL=$(awk -F': ' '/Serial/{print $2; exit}' /proc/cpuinfo 2>/dev/null)
echo "${SERIAL:-0123456789}" > "${G}/strings/0x409/serialnumber"
echo "Luckfox" > "${G}/strings/0x409/manufacturer"
echo "Lyra Plus" > "${G}/strings/0x409/product"

mkdir -p "${G}/configs/c.1/strings/0x409"
echo "CDC ECM + ACM" > "${G}/configs/c.1/strings/0x409/configuration"
echo 250 > "${G}/configs/c.1/MaxPower"

# CDC ECM (Linux/macOS) Ethernet + ACM serial console (/dev/ttyGS0).
mkdir -p "${G}/functions/ecm.usb0"
mkdir -p "${G}/functions/acm.usb0"
ln -sf "${G}/functions/ecm.usb0" "${G}/configs/c.1/"
ln -sf "${G}/functions/acm.usb0" "${G}/configs/c.1/"

UDC=$(ls /sys/class/udc 2>/dev/null | head -n1)
if [ -z "${UDC}" ]; then
    echo "usb-gadget: no UDC found (is usb20_otg0 in peripheral mode?)" >&2
    exit 1
fi
echo "${UDC}" > "${G}/UDC"
echo "usb-gadget: bound CDC-ECM gadget to ${UDC} (interface usb0)"
