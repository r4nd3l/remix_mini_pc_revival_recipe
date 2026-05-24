# Remix Mini PC: Moving the Whole Operating System Onto the eMMC

The previous post ended with a working cold boot. Plug in power, the BROM loads our TOC0 SPL from sector 16 of the SD card, our U-Boot runs, Armbian comes up to a login prompt. No laptop, no FEL, no manual intervention.

There was just one cosmetic issue. The SD card was still required.

If you pulled it out, the device fell straight to FEL because the BROM had nothing else to boot. That's not actually a problem in most usage, but it bothered me. The whole point of internal storage is that you don't need external media. A 16 GB eMMC is sitting right there on the mainboard, untouched since the project began, except for the small TOC0 SPL I had written to its boot partition during placement experiments and which the BROM had never accepted.

So: one more push. Move everything onto the eMMC, eject the SD card forever.

## The unknown that wasn't

I had spent a long evening earlier in the project writing TOC0 SPLs to the eMMC's **boot partition** (`/dev/mmcblk2boot0`) at offset 0 and offset 0x2000, both with the same result every time: BROM silent, no SPL banner, device falls to FEL. I had concluded from this that "the eMMC boot partition is not the right place" — but I had never finished the obvious next experiment. I had never written a TOC0 SPL to the **user area** at sector 16, which is the exact offset that works on SD.

It is embarrassing how easy this was to test. From inside Armbian (booted from the SD as usual), with the boot partition's read-only flag still in its default state (we don't even need to unlock it because the user area is fully writable):

```
sudo dd if=~/uboot-build/u-boot/u-boot-sunxi-with-spl.bin \
        of=/dev/mmcblk2 bs=512 seek=16 conv=fsync
```

Power off. Pull the SD out. Plug power back in. Watch the UART.

```
U-Boot SPL 2026.07-rc2-g744cf5d4e398-dirty
DRAM: 2048 MiB
Trying to boot from MMC2
NOTICE:  BL31: ...
NOTICE:  BL31: Found U-Boot DTB at 0x20ad278, model: Remix Mini PC
...
=>
```

The BROM had just loaded our TOC0 SPL from the eMMC user area at sector 16, same offset as SD. The whole "the eMMC boot partition is the special boot device" mental model was wrong. Allwinner BROM on this device treats the eMMC user area and the SD card the same way — it scans them for a TOC0 signature at sector 16 and runs whatever it finds. The boot partitions are a separate eMMC feature the BROM does not use here.

The U-Boot prompt at the end is just because there is no Linux rootfs on the eMMC yet, so U-Boot has nothing to chain to. But the hard part — getting BROM to accept eMMC — was over the moment I tried the right offset.

## The rootfs migration

Once the eMMC was a usable boot device, the remaining work was straightforward Linux administration. Create a partition on the eMMC user area starting at 16 MiB (well clear of the SPL at sector 16), format it ext4, rsync the SD's contents over, fix up the bootloader config to point at the new UUID.

```
sudo parted -s /dev/mmcblk2 mklabel msdos
sudo parted -s /dev/mmcblk2 mkpart primary ext4 16MiB 100%
sudo partprobe /dev/mmcblk2
```

Then immediately I learned something I had not known about `parted`. After running `mklabel msdos`, my TOC0 SPL at sector 16 was gone:

```
$ sudo dd if=/dev/mmcblk2 bs=512 skip=16 count=1 | hexdump -C | head -1
00000000  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00
```

Zeros. `parted` does not just write the 512-byte MBR at sector 0; it zeros some configurable amount of leading sectors to scrub residual filesystem signatures and old SPL data. The exact size depends on parted's version and the device, but on my install it was at least 8 KiB — which is exactly where my SPL lived.

This was completely recoverable — the SPL file was still on disk, one `dd` puts it back at sector 16 — but it's a real gotcha for anyone doing this in the same order I did. The right ordering is:

1. Create the partition table **first** with parted.
2. Then write the SPL at sector 16.
3. The partition itself starts at sector 32768, so nothing else touches sector 16 again.

After restoring the SPL and verifying, `mkfs.ext4 -L armbi_emmc /dev/mmcblk2p1` formats the partition cleanly without touching the bootloader region. `rsync -aHAXx / /mnt/emmc/` copies the current SD rootfs over while running on top of it. About 89,000 files and 2.1 GB. Nine minutes at SD-card-speed.

## The variable substitution trap

Inside the eMMC copy, two files needed editing:

- `/etc/fstab` — the kernel needs to know which device to mount as root.
- `/boot/armbianEnv.txt` — the U-Boot boot script reads this to pass the `root=` parameter to the kernel.

Both currently referenced the SD card's UUID. They needed to reference the eMMC partition's UUID instead. Easy substitution, four shell commands:

```
SD_UUID=$(sudo blkid -s UUID -o value /dev/mmcblk0p1)
EMMC_UUID=$(sudo blkid -s UUID -o value /dev/mmcblk2p1)
sudo sed -i "s|$SD_UUID|$EMMC_UUID|g" /mnt/emmc/etc/fstab
sudo sed -i "s|$SD_UUID|$EMMC_UUID|g" /mnt/emmc/boot/armbianEnv.txt
```

I ran the first command. I skipped the second by accident — possibly the multi-line paste cut off, possibly I just didn't notice it. The third and fourth commands ran with `$EMMC_UUID` set to an empty string, and `sed` happily did exactly what I told it to: replace the SD UUID with nothing. The result was a fstab that read:

```
UUID= / ext4 defaults,noatime,...
```

and an `armbianEnv.txt` that read `rootdev=UUID=`. The eMMC rootfs would have failed to mount on boot in a way that would have been hard to debug at three in the morning.

The verify step — printing both files after the substitution — is what caught it. I noticed the UUID column was suddenly empty, looked at the variables, found `$EMMC_UUID` was unset, set it explicitly, ran a targeted sed to put the right UUID back. Twenty seconds of fix work because of a verify step that took ten seconds. Always print before and after.

## The final test

After fixing fstab and armbianEnv, unmounting cleanly, and writing one last `sync`:

```
sudo poweroff
```

Unplug power. Pull SD card out (critical — the BROM tries SD first, and if it finds the SD's TOC0 SPL it'll boot from there regardless of whether the eMMC also has one). Plug power back in.

```
U-Boot SPL 2026.07-rc2-g744cf5d4e398-dirty
DRAM: 2048 MiB
Trying to boot from MMC2                          ← eMMC, not SD
NOTICE:  BL31: ...
NOTICE:  BL31: Found U-Boot DTB at 0x20ad278, model: Remix Mini PC

U-Boot 2026.07-rc2 Allwinner Technology
CPU:   Allwinner A64 (SUN50I)
Model: Remix Mini PC
DRAM:  2 GiB
...
MMC: no card present                              ← SD physically removed
...
switch to partitions #0, OK
mmc1(part 0) is current device
Scanning mmc 1:1...                               ← eMMC partition 1
Found U-Boot script /boot/boot.scr
...
Starting kernel ...

Armbian 24.11.1 Bookworm ttyS0

pine64 login:

 v24.11.1 for Pine64 running Armbian Linux 6.6.62-current-sunxi64
 Usage of /:  17% of 15G                          ← root mounted from eMMC
```

Full Armbian login. No SD card in the device. No laptop attached. The Remix Mini PC is now genuinely autonomous: plug in power, after about twenty seconds it is running Linux, ready to be SSH'd into or used directly through HDMI and a USB keyboard.

The boot trace is worth comparing to the previous post's. Same SPL build, same BL31, same U-Boot, same kernel, same rootfs — but the source has shifted from "SD card sector 16" to "eMMC user area sector 16." The SD card is no longer required for any part of the chain.

## What this finishes

The original project goal — turn the device into something that boots its own operating system from its own internal storage without a host PC — is done. There is a small list of polish items left (the wired Ethernet is still off, the kernel-side device tree is still a patched BananaPi-M64 rather than a true Remix DTS, the eMMC could be using its boot partition more cleverly) but nothing on that list is blocking. The machine works.

The SD card, freshly imaged and gzip-backed-up at 893 MB, goes into a drawer as a recovery boot media. The two Remix Mini PCs on my desk — one with eMMC, one without — are both functional Linux SBCs as of this evening.

## Lessons that I'd put on a sticky note

- **Test the obvious-but-untested case before getting deep into the non-obvious ones.** Writing TOC0 to the eMMC user area at sector 16 — the same offset that works on SD — was the simplest possible experiment, and I never ran it until very late in the project. Hours of "the boot partition won't accept TOC0" investigation could have been compressed into one `dd` command.

- **`parted mklabel` zeros more than just the MBR.** If you have anything in the first few kilobytes of a disk that you want to keep, write it *after* you create the partition table.

- **Empty shell variables make sed eat data.** `sed 's|X|$Y|g'` with `$Y` unset does not error; it silently substitutes X with nothing. Always echo your variables before passing them to sed.

- **Verify steps are not optional.** Every single bug in this project was caught by either a UART log or a "print the file after editing" command. Every single one was lost time when those verifies were skipped.

Three years between buying the device and getting it to boot on its own. About twenty seconds between power-on and login prompt now. That's the trade I would make again.
