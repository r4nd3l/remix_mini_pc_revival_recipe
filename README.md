# Remix Mini PC — Cold-Boot Recipe

A self-contained set of files for reviving the Jide Remix Mini PC (RM1G / RM2G), so
that it boots Linux from internal storage without needing a laptop and FEL sideload.

Hardware: Allwinner H64 SoC (= rebadged A64), 2 GB RAM, 16 GB eMMC,
WiFi (rtl8723bs), HDMI, USB 2.0, and 10/100 wired Ethernet through the AC200
companion chip, which needs the extra steps in [Wired Ethernet](#wired-ethernet-the-ac200-port).

> **Confirmed on two unit variants**: the standard RM1G/RM2G with eMMC, and a
> board with the eMMC chip removed. The same SD card boots either. No
> per-unit tweaks needed.

## What this fixes

The Remix Mini PC's BROM has the "secure boot" eFuse burned. That makes it
**refuse** standard sunxi `eGON.BT0`-format boot code from SD card or eMMC.
With no second-stage bootloader the device falls into FEL mode silently and
requires a USB-OTG sideload to start.

There is no public ROTPK key fused into the chip, so the BROM does not check
the *signer*, only the *format*: it accepts **TOC0**-wrapped SPLs signed with
any key. With a TOC0-wrapped U-Boot in the right place on the SD card, the
device will cold-boot all the way to Linux on its own.

## Contents

```
precompiled/
  u-boot-sunxi-with-spl.bin       Pre-built TOC0-signed SPL + U-Boot. Just flash it.
source/
  remix-mini-pc_defconfig         U-Boot defconfig - copy into configs/ before make.
scripts/
  flash-toc0-to-sd.sh             One-liner to write the SPL to an SD card.
kernel/
  cs-dwmac-sun8i-tolerate-probe-reset.patch   Kernel patch for the wired Ethernet.
overlays/
  ac200-eth-v6.dts                Device-tree overlay for the wired Ethernet (v1-v5: history).
system/
  05-cs-eth0.network              systemd-networkd: DHCP on eth0, preferred over Wi-Fi.
  r8723bs.conf                    Wi-Fi power saving off (fewer drop-outs).
  cpu-governor.tmpfiles.conf      schedutil instead of a pinned governor (runs cooler).
  journald-persistent.conf        Keep the journal across crashes.
notes/
  ethernet-ac200.md               The full Ethernet investigation, register by register.
```

You also need an **Armbian SD card image** (kernel + rootfs) — see below.
The TOC0 SPL only replaces the bootloader portion; the kernel and rootfs
on the SD remain Armbian's standard setup.

## Quickest start — pre-built SD image

If you don't want to assemble anything yourself, grab the ready-to-flash SD
image from the [latest release](https://github.com/r4nd3l/remix_mini_pc_revival_recipe/releases/latest):

- **`armbian-remix-mini-pc-v1.0.0.img.gz`** (363 MB compressed, 1.2 GB on disk)

It's the official Armbian Pine64 24.11.1 minimal image with this project's
TOC0 SPL pre-installed at sector 16, the vqmmc-patched bananapi-m64 DTB
swapped into `/boot/dtb/allwinner/`, and `fdtfile=` set in `armbianEnv.txt`.
The image has never been booted, so Armbian's first-login wizard runs fresh
on the user's machine.

```
gunzip -c armbian-remix-mini-pc-v1.0.0.img.gz \
  | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

Insert the SD into your Remix Mini PC, plug in power. That's it.

If you want to know what's in the image or build your own from scratch
(recommended for anything resembling production use, since the pre-built
image is signed with my personal key), continue with the "Quick start"
recipe below.

SHA256 of the .gz: `87753fd64c1a84a54a96a88b88bdf068ec7e0903f216b9642f0f0661149d8b00`
SHA256 of the unpacked .img: `2233b3b46e10e9d58ed2c49bb160abe90697922e523329a97c9ce4508fbe9b66`

## Quick start (use the pre-built SPL)

1. Flash a standard Armbian image to an SD card:
   ```
   sudo dd if=Armbian_..._Pine64_bookworm_current_..._minimal.img \
           of=/dev/sdX bs=4M status=progress conv=fsync
   sync
   ```
   The Armbian "Pine64" minimal image works; "BananaPi-M64" image works too.

2. Overlay the TOC0 SPL on top, at sector 16:
   ```
   sudo ./scripts/flash-toc0-to-sd.sh /dev/sdX precompiled/u-boot-sunxi-with-spl.bin
   ```

3. Mount the SD's rootfs to add a kernel device-tree override.
   The U-Boot defconfig defaults to `sun50i-h64-remix-mini-pc.dtb`, which the
   stock Armbian kernel package doesn't ship. Force U-Boot to use the
   BananaPi-M64 DTB instead (close enough to the Remix's hardware that
   it boots; you'll want to patch in `vqmmc-supply` for the eMMC):
   ```
   sudo mount /dev/sdX1 /mnt
   echo "fdtfile=allwinner/sun50i-a64-bananapi-m64.dtb" | \
       sudo tee -a /mnt/boot/armbianEnv.txt
   sudo umount /mnt
   ```

4. (Optional, only if you want the eMMC to be usable from Linux later)
   Patch the bananapi-m64 DTB to add `vqmmc-supply` pointing at `eldo1`
   (1.8 V I/O voltage rail). Without this, the eMMC enumerates but data
   transfers fail. This patch is what unlocked the eMMC for me — see the
   companion blog post on the missing `vqmmc-supply` property.

   **Easy path** — drop in the pre-patched DTB from this bundle. The file
   is shipped as `sun50i-a64-bananapi-m64-vqmmc-patched.dtb` for clarity,
   but it has to be installed without the suffix so U-Boot finds it:
   ```
   sudo cp precompiled/sun50i-a64-bananapi-m64-vqmmc-patched.dtb \
           /mnt/boot/dtb/allwinner/sun50i-a64-bananapi-m64.dtb
   ```

   **Manual path** — patch the upstream DTB yourself:
   ```
   # Find eldo1's phandle in the DTB (usually around 0x4e)
   sudo dtc -I dtb -O dts /mnt/boot/dtb/allwinner/sun50i-a64-bananapi-m64.dtb \
       | grep -B1 -A5 "eldo1 {"
   # Add the property (replace 0x4e with whatever phandle eldo1 has)
   sudo fdtput -t i /mnt/boot/dtb/allwinner/sun50i-a64-bananapi-m64.dtb \
       /soc/mmc@1c11000 vqmmc-supply 0x4e
   ```

5. Insert SD, plug power. The Remix should now boot Armbian on its own,
   no laptop attached. Login prompt appears on UART (115200 8N1) and on
   HDMI if a monitor is connected.

## Going SD-free — migrate everything to the eMMC

The SD-card recipe above gets the device booting on its own, but it still
needs the SD card physically inserted. If you have the eMMC variant (any
unit *with* an internal storage chip) you can move the entire boot chain
onto the eMMC and never plug another SD card in. Same TOC0 SPL works on
either medium — the Allwinner BROM checks the eMMC user area at sector 16
the same way it checks the SD card.

Run these steps **from inside Armbian** while booted from the SD card:

1. Write the TOC0 SPL to the eMMC user area at sector 16:
   ```
   sudo dd if=/path/to/u-boot-sunxi-with-spl.bin \
           of=/dev/mmcblk2 bs=512 seek=16 conv=fsync
   sync
   ```

2. Create a partition table on the eMMC user area, then re-write the SPL.
   `parted mklabel` zeros sectors beyond the MBR, so the SPL has to go
   *after* the partition is created, not before:
   ```
   sudo parted -s /dev/mmcblk2 mklabel msdos
   sudo parted -s /dev/mmcblk2 mkpart primary ext4 16MiB 100%
   sudo partprobe /dev/mmcblk2
   sudo dd if=/path/to/u-boot-sunxi-with-spl.bin \
           of=/dev/mmcblk2 bs=512 seek=16 conv=fsync
   sync
   ```

3. Format and rsync the rootfs over:
   ```
   sudo mkfs.ext4 -L armbi_emmc /dev/mmcblk2p1
   sudo mkdir -p /mnt/emmc
   sudo mount /dev/mmcblk2p1 /mnt/emmc
   sudo rsync -aHAXx --info=progress2 / /mnt/emmc/
   sudo mkdir -p /mnt/emmc/{proc,sys,dev,run,tmp,mnt,media}
   ```

4. Point fstab and armbianEnv.txt on the eMMC copy at the new UUID. Make
   sure both UUIDs are populated before running sed — an empty variable
   will silently *delete* the UUID instead of replacing it:
   ```
   SD_UUID=$(sudo blkid -s UUID -o value /dev/mmcblk0p1)
   EMMC_UUID=$(sudo blkid -s UUID -o value /dev/mmcblk2p1)
   echo "SD=$SD_UUID  EMMC=$EMMC_UUID"      # verify both have values
   sudo sed -i "s|$SD_UUID|$EMMC_UUID|g" /mnt/emmc/etc/fstab
   sudo sed -i "s|$SD_UUID|$EMMC_UUID|g" /mnt/emmc/boot/armbianEnv.txt
   sync
   sudo umount /mnt/emmc
   ```

5. Power off, pull the SD card out, plug power back in. The BROM now
   finds the TOC0 SPL on the eMMC user area, U-Boot reads boot.scr from
   the eMMC partition, the kernel mounts the eMMC partition as root,
   Armbian comes up to a login prompt. **No SD card present.**

The SD card with the TOC0 SPL still works as a backup boot path — keep it
in a drawer. The BROM tries the SD first on each cold boot; if it's
absent, it falls through to the eMMC.

## Build from source (reproduce the SPL yourself)

You probably want your own signing key. Build natively on the Remix itself
(while it's running via FEL+sideload) or on any aarch64 / cross-compile host.

```
sudo apt install -y build-essential bc bison flex libssl-dev libgnutls28-dev \
                    python3 python3-pyelftools python3-dev python3-setuptools \
                    swig device-tree-compiler u-boot-tools git \
                    arm-trusted-firmware

mkdir -p ~/uboot-build && cd ~/uboot-build
git clone --depth 1 https://source.denx.de/u-boot/u-boot.git
cd u-boot

# Step 1: drop in the defconfig
cp /path/to/blog-assets/source/remix-mini-pc_defconfig configs/

# Step 2: add the Remix DTB to the build list. The DTS is already in mainline.
# Open arch/arm/dts/Makefile, find the line:
#       sun50i-a64-teres-i.dtb
# inside dtb-$(CONFIG_MACH_SUN50I) += \ ... block, and change it to:
#       sun50i-a64-teres-i.dtb \
#       sun50i-h64-remix-mini-pc.dtb
# (i.e. add a trailing backslash and one new line.)
#
# Or programmatically:
awk '/sun50i-a64-teres-i\.dtb/ && !/h64-remix/ {
        print $0 " \\"; print "\tsun50i-h64-remix-mini-pc.dtb"; next
     } { print }' arch/arm/dts/Makefile > /tmp/Makefile.new
mv /tmp/Makefile.new arch/arm/dts/Makefile

# Step 3: generate a signing key
openssl genrsa -out root_key.pem 2048

# Step 4: tell U-Boot where to find BL31
# Debian ships a pre-built one that works fine:
export BL31=/usr/lib/arm-trusted-firmware/sun50i_a64/bl31.bin

# Step 5: configure and build
make remix-mini-pc_defconfig
make -j$(nproc)

# Verify the result starts with TOC0:
head -c 8 u-boot-sunxi-with-spl.bin | xxd
#   should show: 5443 4f30 2e47 4c48   "TOC0.GLH"
```

The `u-boot-sunxi-with-spl.bin` is what goes onto the SD card.

## Wired Ethernet (the AC200 port)

The RJ45 port is not driven by the SoC alone. Its PHY lives in an **X-Powers AC200**
companion chip (on I2C, address 0x10) and talks to the A64's EMAC over **RMII**. Stock
Armbian brings none of it up. Three things make it work (tested on Armbian 26.5.1,
kernel 6.18.33, `BOARD=pine64`, `fdtfile=allwinner/sun50i-h64-remix-mini-pc.dtb`):

1. **The AC200's 24 MHz clock comes from the SoC**, not from a crystal: the factory
   Remix OS kernel runs R_PWM channel 0 on pin **PL10** at ~24 MHz (found in the factory
   image's `sys_config.fex`, DTB and the BSP `acx00` driver). The overlay re-creates that
   as a `pwm-clock` (period 42 ns, which the sun4i-pwm driver turns into a straight
   bypass of the 24 MHz oscillator).
2. **The PHY node owns the AC200 EPHY clock gate and reset**, with
   `reset-names = "phy"` so phylib finds the reset and releases it when the port opens.
3. **A one-line kernel patch**: the AC200 drivers are modules and load after the EMAC
   probes, so the EMAC's probe-time reset times out without a clock. Stock
   `dwmac-sun8i` then tears the device down; the patch makes it warn and carry on.
   The MAC is reset again, clocked, when the interface opens.

Result: 100 Mbit/s full duplex, DHCP, ~43 Mbit/s measured with zero errors, and it
comes up on its own after a cold boot.

### 1. Build and install the patched kernel

On an x86-64 or arm64 Linux host with the
[Armbian build framework](https://github.com/armbian/build) (tag `v26.5.1`):

```
cp kernel/cs-dwmac-sun8i-tolerate-probe-reset.patch \
   <armbian-build>/userpatches/kernel/archive/sunxi-6.18/
cd <armbian-build>
./compile.sh kernel BOARD=pine64 BRANCH=current KERNELBRANCH=tag:v6.18.33 \
             KERNEL_CONFIGURE=no KERNEL_GIT=shallow
```

Copy `output/debs/linux-image-current-sunxi64_*.deb` and
`linux-dtb-current-sunxi64_*.deb` to the Remix, then:

```
sudo dpkg -i linux-image-current-sunxi64_*.deb linux-dtb-current-sunxi64_*.deb
sudo apt-mark hold linux-image-current-sunxi64 linux-dtb-current-sunxi64
```

The hold stops a routine `apt upgrade` from replacing it with the unpatched kernel.
Keep the stock debs somewhere as a fallback.

### 2. Install the overlay

```
dtc -@ -I dts -O dtb -o ac200-eth.dtbo overlays/ac200-eth-v6.dts
sudo mkdir -p /boot/overlay-user
sudo cp ac200-eth.dtbo /boot/overlay-user/
```

and in `/boot/armbianEnv.txt`:

```
overlay_prefix=sun50i-a64
user_overlays=ac200-eth
```

### 3. Network config

```
sudo cp system/05-cs-eth0.network /etc/systemd/network/
```

It asks for DHCP on `eth0` with route metric 100, so the cable wins over Wi-Fi
(metric 600), which stays up as the fallback. `RequiredForOnline=no` keeps the boot
from waiting when no cable is plugged in.

### 4. Power-cycle

Pull the power and plug it back in; the overlay is applied by U-Boot at boot. **On this
board a warm `reboot` may hang after "Journal stopped"**: power-cycle instead. Then:

```
networkctl status eth0        # routable, with a DHCP address
ip route                      # default via eth0 metric 100, wlan0 metric 600
```

Do not poke the AC200 over I2C by hand while the kernel drivers own it: it is paged
through register 0xfe and the kernel caches the page, so a stray write leaves it on the
wrong page. Read it through `/sys/kernel/debug/regmap/1-0010-AC200/registers` instead.

## Known limitation: no audio

The analog codec probes and the mixer works, but playback and capture fail
straight away with `Input/output error`. The I2S block runs, yet its TX FIFO
stays empty and the DMA controller never raises an interrupt.

Most likely cause: on a secure-boot-fused chip the DMA channels start out
secure-only. TF-A's `sunxi_security_setup()` writes `DMA_SEC` (offset 0x20)
to hand them to the normal world, but at that point the DMA bus clock is
still gated, so the write is probably lost. This has not been verified,
because it would need raw register access. A plain Pine64 is not fused, so
it never shows the problem.

Probable fix (untested): patch BL31 to ungate the DMA clock and deassert its
reset before that write, then rebuild the TOC0 SPL. Test it from an SD card
first. Not needed for a headless server, so it has been left alone.

## Recovery if something breaks

The BROM **always** falls back to FEL mode when nothing else boots, and FEL
mode cannot be disabled on a chip with no ROTPK fused. So you can never
permanently brick the device this way.

To recover after a botched flash:
1. Disconnect any USB device from the OTG port.
2. Power on. If it boots normally, great.
3. If silent, hold the FEL trigger (a paperclip into the small hole on the
   bottom, or short the FEL pads on the board) while powering on.
4. On your PC: `lsusb | grep Allwinner` should show the FEL device.
5. `sudo sunxi-fel uboot <path-to-known-working-eGON-u-boot-sunxi-with-spl.bin>`
   to bring the device back up.

## Credits and references

- Andre Przywara's U-Boot patch series (April 2024) that added Remix Mini PC support.
  Series identifier on `lore.kernel.org/u-boot/`:
  `20240424001808.14388-1-andre.przywara@arm.com`
- The mainline Linux device tree:
  `arch/arm64/boot/dts/allwinner/sun50i-h64-remix-mini-pc.dts`
- `linux-sunxi.org/Jide_Remix_Mini` — the wiki page where I finally read the
  sentence about the secure-boot fuse and believed it.
- The factory image `factory_image_rm1g_B2016110301-secure.img` (Remix OS 2.0.626, on the
  OSDN mirrors under `remixos/66607/`) and the Allwinner BSP driver `drivers/mfd/acx00-core.c`
  — where the AC200's PWM clock on PL10 turned up.
- The AC200 MFD and EPHY drivers by Jernej Škrabec and Andre Przywara, as carried by Armbian (`sunxi-6.18` patches),
  and the H6 boards' device trees that wire them.

## Companion blog posts

The full story behind these files, published on dev.to. Each post is also
mirrored in the `posts/` directory of this repo, in case external links go away.

1. *Remix Mini PC: After a Year of Dead Ends, the eMMC Finally Talks*
   — [dev.to](https://dev.to/matemiller/remix-mini-pc-after-a-year-of-dead-ends-the-emmc-finally-talks-16p6)
   · [local copy](posts/01-emmc-breakthrough-vqmmc-supply.md)
2. *Remix Mini PC: Confirming What Stands Between Us and Cold Boot*
   — [dev.to](https://dev.to/matemiller/remix-mini-pc-confirming-what-stands-between-us-and-cold-boot-5b12)
   · [local copy](posts/02-secure-boot-confirmed-toc0.md)
3. *Remix Mini PC: The Day It Finally Booted Itself*
   — [dev.to](https://dev.to/matemiller/remix-mini-pc-the-day-it-finally-booted-itself-o2l)
   · [local copy](posts/03-toc0-cold-boot-victory.md)
4. *Remix Mini PC: The Same SD Card Boots the No-NAND Variant Too*
   — [dev.to](https://dev.to/matemiller/remix-mini-pc-the-same-sd-card-boots-the-no-nand-variant-too-4p0h)
   · [local copy](posts/04-no-nand-variant-works-too.md)
5. *Remix Mini PC: Moving the Whole Operating System Onto the eMMC*
   — [dev.to](https://dev.to/matemiller/remix-mini-pc-moving-the-whole-operating-system-onto-the-emmc-h3h)
   · [local copy](posts/05-emmc-migration-no-more-sd-card.md)

The full series and the author's other writing live at
<https://dev.to/matemiller>.
