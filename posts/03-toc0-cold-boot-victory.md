# Remix Mini PC: The Day It Finally Booted Itself

For more than a year, the Remix Mini PC on my desk could only be brought to life by attaching a laptop and pushing U-Boot into it over USB OTG. Every reboot was a manual ritual: trigger FEL mode, run `sunxi-fel uboot ...`, wait. Useful for development; useless as a real machine.

This is the post about the day that changed.

## Recap: where we were

The previous post pinned down the wall. The Remix Mini PC has the Allwinner A64 "secure boot" eFuse burned, which makes the BROM refuse standard eGON-format SPLs from both the SD card and the eMMC. There is no ROTPK key fused in, so the BROM doesn't actually check who signed the boot code — it just demands the **TOC0** wrapper format. A self-signed TOC0 image, signed with any RSA key, will pass.

That meant the path to a permanent boot was clear: produce a TOC0-wrapped SPL, write it to a place the BROM looks, power-cycle, see what happens.

Easy to write. Less easy to do.

## The U-Boot defconfig that wasn't there

The mainline Linux kernel has had a device tree for the Remix Mini PC since 2023, contributed by Andre Przywara at Arm. The same author also submitted a four-patch series for U-Boot in April 2024 to add full board support, including a `remix-mini-pc_defconfig` with `CONFIG_SPL_IMAGE_TYPE_SUNXI_TOC0=y` — exactly the build switch that produces a TOC0 image.

Only some of that series actually landed in mainline U-Boot. The device tree file was imported. The defconfig and the Makefile glue were not. So a fresh clone of mainline U-Boot today has the DTS file sitting there, but no way to build it — no defconfig, and no entry in the dtb Makefile to compile it as part of any board build.

The defconfig is fourteen lines. The Makefile change is one line. Pulling the patch series from `lore.kernel.org` and extracting just patch 2/4 (which is the Remix-specific one) gave me both:

```
CONFIG_DEFAULT_DEVICE_TREE="sun50i-h64-remix-mini-pc"
CONFIG_SPL=y
CONFIG_MACH_SUN50I=y
CONFIG_DRAM_CLK=672
CONFIG_DRAM_ZQ=4013533
CONFIG_MMC_SUNXI_SLOT_EXTRA=2
CONFIG_SPL_IMAGE_TYPE_SUNXI_TOC0=y
CONFIG_SUPPORT_EMMC_BOOT=y
...
```

`git am` rejected the patch because the surrounding context in `arch/arm/dts/Makefile` had drifted in the two years since the patch was written. So I applied both halves by hand: created the defconfig file directly from the patch's `+` lines, and used a small `awk` to splice the new DTB filename into the right place in the Makefile.

That part went smoothly. The rest of the day did not.

## TF-A is a black hole

The U-Boot build needs ARM Trusted Firmware-A (`bl31.bin`) as the EL3 secure monitor. Standard sunxi64 build step: clone TF-A, `make PLAT=sun50i_a64 bl31`, point U-Boot at the output.

TF-A's build did not cooperate. The first attempt failed because I built it with `DEBUG=1` and the resulting binary was 472 bytes too big for the A64's BL31 SRAM region. Fine, build release. Release said `make: Nothing to be done for 'bl31'`, even after a clean clone in a brand-new directory.

I spent an embarrassing amount of time on this. The cause turned out to be a name collision: TF-A has both a `bl31` makefile target and a `bl31/` source directory in the root of the repo. GNU make sometimes interprets `make bl31` as "build the directory `bl31/`," sees that the directory exists, and concludes there is nothing to do. `make -B` didn't override it. `make all` didn't produce a bl31. Neither did invoking the absolute path of the output file as a target.

After about half an hour, I gave up and searched Debian for a pre-built one:

```
$ dpkg -L arm-trusted-firmware | grep sun50i
/usr/lib/arm-trusted-firmware/sun50i_a64
/usr/lib/arm-trusted-firmware/sun50i_a64/bl31.bin
```

There it was. Debian's `arm-trusted-firmware` package ships pre-built BL31 binaries for many platforms, including sun50i_a64. The version is older than what U-Boot's bleeding-edge build would normally use (TF-A 2.8 from 2022 vs. master), but for our purposes — getting the secure monitor up and getting out of EL3 — it works fine.

```
$ export BL31=/usr/lib/arm-trusted-firmware/sun50i_a64/bl31.bin
$ cd ~/uboot-build/u-boot && make -j4
```

The build needed one more thing it had been complaining about earlier: a signing key. TOC0 images are signed; `mkimage` looks for `root_key.pem` in the build directory. The error message even tells you the cure:

```
mkimage (TOC0): info: Try 'openssl genrsa -out root_key.pem'
```

Since the BROM does not check the key against a fused root-of-trust hash, any RSA key works. I generated a 2048-bit one on the spot. Reproducible enough — just keep the file around.

The build finished. The first eight bytes of `u-boot-sunxi-with-spl.bin` were:

```
54 4f 43 30 2e 47 4c 48   |TOC0.GLH|
```

Right magic. Worth trying.

## The placement experiments

The eMMC's boot partition was the obvious target. PARTITION_CONFIG was already set to 0x48 — boot from boot partition 1 — so writing the new SPL to `/dev/mmcblk2boot0` at offset 0 should have been the cleanest possible test.

Wrote it, power-cycled, watched the UART. Silence. The green LED came on, the BROM accepted no boot code, the device sat in FEL mode waiting for a USB sideload. Same outcome that I had been fighting for a year.

Tried offset 8 KiB instead — that's where sunxi SPL lives on SD cards. Same silence. (I also discovered that Linux re-applies the eMMC boot partition's read-only flag on every boot, so my "second" write had silently failed. That cost another ten minutes of confusion before I caught the `Operation not permitted` in the `dd` output.)

The thing that finally worked was the most embarrassing one: write the same TOC0 to the **SD card** at sector 16, the standard sunxi SD SPL offset.

```
$ sudo dd if=u-boot-sunxi-with-spl.bin of=/dev/mmcblk0 bs=512 seek=16 conv=fsync
```

Pull power. Plug power. Watch the UART.

```
U-Boot SPL 2026.07-rc2-g744cf5d4e398-dirty (May 22 2026 - 22:23:12 +0200)
DRAM: 2048 MiB
Trying to boot from MMC1
NOTICE:  BL31: v2.8(release):
NOTICE:  BL31: Detected Allwinner A64/H64/R18 SoC (1689)
NOTICE:  BL31: Found U-Boot DTB at 0x20ad278, model: Remix Mini PC

U-Boot 2026.07-rc2-g744cf5d4e398-dirty Allwinner Technology

CPU:   Allwinner A64 (SUN50I)
Model: Remix Mini PC
DRAM:  2 GiB
```

The one line that meant everything: `Model: Remix Mini PC`. For more than a year, every boot of this device — when it booted at all — had announced itself as a BananaPi-M64, because that was the closest mainline U-Boot defconfig I could compile. This time, for the first time, U-Boot reported the device's actual name. The BROM had loaded my self-signed TOC0. The secure boot wall was a key the device was willing to copy off itself.

## The last small obstacle

U-Boot kept going and tried to boot Linux, but failed:

```
File /boot/dtb/allwinner/sun50i-h64-remix-mini-pc.dtb does not exists
```

The new defconfig sets `CONFIG_DEFAULT_DEVICE_TREE="sun50i-h64-remix-mini-pc"`, so when U-Boot's boot script asks the SD card for a kernel device tree, it asks for that filename — but the Armbian image on the card was built for `sun50i-a64-bananapi-m64` and doesn't ship the Remix DTB.

A two-line fix. Mount the SD card on my laptop, append `fdtfile=allwinner/sun50i-a64-bananapi-m64.dtb` to `armbianEnv.txt`, copy the newly-built remix DTB to `/boot/dtb/allwinner/` as a fallback. Reinsert.

Power-cycle. Without touching the laptop afterwards. The SPL banner scrolled, U-Boot loaded, the boot script ran, the kernel started, Armbian came up, the login prompt appeared.

Plug power, it runs.

## What this looks like now

The Remix Mini PC is no longer a glorified paperweight. The boot chain is entirely my own:

```
silicon BROM
  -> SD sector 16:    TOC0-signed U-Boot SPL (mainline U-Boot, signed with my key)
     -> BL31:         Debian's pre-built TF-A 2.8 for sun50i_a64
        -> U-Boot:    mainline 2026.07-rc2 with remix-mini-pc_defconfig
           -> /boot/boot.scr -> Image + initrd + bananapi-m64 DTB (with my vqmmc patch)
              -> Linux 6.6.62 -> Armbian login
```

No laptop. No FEL. No magic. Just power.

There are still loose ends. The Linux side is still using a patched BananaPi-M64 device tree rather than the proper Remix one, because that is what the Armbian kernel package has prebuilt and I have not built a kernel against the upstream Remix DTS yet. The eMMC is unused — the boot chain lives on the SD card, because that is where the BROM is willing to read TOC0. I can probably get the eMMC into the boot path too, but it is no longer urgent now that the device just works.

## Reflections

A few things from the journey worth holding onto.

**The wiki was right and I should have believed it sooner.** The linux-sunxi page for this device says, almost in passing, "the SoC has the secure boot fuse burned, so it will not accept any standard eGON boot media." I read that line a year ago and assumed it was something esoteric and untestable. It was the single most important fact about the device.

**Half-merged upstream support is more common than you would think.** The DTS file for this device sits in mainline Linux *and* in mainline U-Boot, but the U-Boot defconfig that ties it together never landed. It is one small patch file on a mailing list, easy to apply by hand once you find it. If you are reviving an obscure SBC, search the mailing list archives before assuming you have to write everything yourself.

**Old tools are sometimes still right.** I spent an hour fighting TF-A's build system trying to produce a fresh BL31 binary. The bl31 that ended up being executed is a 2022 build from a Debian package, and the device booted with it the first time I tried. Doing the unfashionable thing was the fastest path.

**The diagnostic that mattered was the UART line.** Once I could see "Model: Remix Mini PC" instead of "BananaPi-M64," I knew exactly what I had done — and what to fix next. Every interesting debugging moment in this project has happened over a serial cable. Buy the cable.

This was the last big wall. Whatever comes next on this device is application work, not survival work. After more than a year, that feels different in a way that is hard to write down.

The Remix Mini PC is alive on its own.
