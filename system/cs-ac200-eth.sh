#!/bin/sh
# Wired Ethernet on the Remix Mini PC (AC200 PHY) — see remix_mini_pc_revival_recipe notes/ethernet-ac200.md.
# The built-in EMAC probes before the AC200 modules exist and gives up ("EMAC reset timeout": no PHY clock).
# Here: load the AC200 drivers, open the EPHY clock gate + release its reset (SYS_EPHY_CTL0 = 0x0003),
# then bind the EMAC again. The AC200 is big-endian on I2C and paged through 0xfe; the kernel regmap
# caches the page, so the selector is put back afterwards.
set -e
modprobe ac200; modprobe ac200-ephy-ctl; modprobe ac200-phy
for i in $(seq 1 20); do i2cget -f -y 1 0x10 0x00 w >/dev/null 2>&1 && break; sleep 0.5; done
page=$(i2cget -f -y 1 0x10 0xfe w)
i2cset -f -y 1 0x10 0xfe 0x0000 w
i2cset -f -y 1 0x10 0x14 0x0300 w
i2cset -f -y 1 0x10 0xfe "$page" w
sleep 0.5
[ -e /sys/class/net/eth0 ] || echo 1c30000.ethernet > /sys/bus/platform/drivers/dwmac-sun8i/bind
