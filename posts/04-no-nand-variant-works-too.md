# Remix Mini PC: The Same SD Card Boots the No-NAND Variant Too

A short coda to the last three posts.

I have a second Remix Mini PC on my desk. It looks identical to the first one — same case, same back panel, same ports — except the previous owner had removed the eMMC chip from the mainboard. No internal storage at all. For years I had assumed it was a separate problem to solve, that one day I would need to find a different recipe for the no-NAND variant.

After getting the first unit cold-booting from an SD card, I wondered: how much of the work is actually unit-specific, and how much is just "this is what an Allwinner H64 with secure boot wants"? The honest answer is, you cannot tell without trying.

So I pulled the SD card out of the working unit, unplugged the UART wires, and walked them across to the no-NAND machine. Wired everything back up — brown to GND, yellow to RX, orange to TX, leaving VCC unconnected, just like the original unit. Cleared the UART log on my laptop. Plugged in power.

The boot log that came back was, byte-for-byte, the same as on the unit with eMMC:

```
U-Boot SPL 2026.07-rc2-g744cf5d4e398-dirty
DRAM: 2048 MiB
Trying to boot from MMC1
NOTICE:  BL31: Detected Allwinner A64/H64/R18 SoC (1689)
NOTICE:  BL31: Found U-Boot DTB at 0x20ad278, model: Remix Mini PC

U-Boot 2026.07-rc2-g744cf5d4e398-dirty Allwinner Technology

CPU:   Allwinner A64 (SUN50I)
Model: Remix Mini PC
DRAM:  2 GiB
...
Starting kernel ...

Armbian 24.11.1 Bookworm ttyS0
pine64 login:
```

The TOC0 SPL was accepted by the BROM. DRAM training landed on the same 2 GiB. BL31 ran. U-Boot proper announced itself as "Model: Remix Mini PC." The Armbian kernel started. The login prompt appeared. The whole pipeline I described in the previous post worked, unchanged, on a board with one major chip physically absent.

## What this tells me

A few things, all small but worth recording.

**The recipe is the silicon, not the board.** Once the BROM, the secure-boot fuse, and the DRAM controller are the same, the boot chain does not actually care whether eMMC is present. The Allwinner A64/H64 family has three MMC controllers as part of the SoC itself; U-Boot enumerates all three regardless of what is wired to them. The line

```
MMC:   mmc@1c0f000: 0, mmc@1c10000: 2, mmc@1c11000: 1
```

prints identically on both units. The difference is only at scan time — `mmc 2` finds an eMMC card on one unit and finds nothing on the other. The SD card on `mmc 0` is the same on both.

**One SD card revives any Remix Mini PC.** That is a useful property for anyone trying this at home. You do not have to characterize the device in front of you to know which recipe applies. Make the SD card once, plug it into whatever Remix you have, power on.

**The no-NAND unit is the better test bench.** This is the practical consequence I will probably get the most use out of. The unit with eMMC carries years of accumulated bootloader state in its boot partitions; even after this project, those boot partitions still contain mixed eGON and TOC0 artifacts from my placement experiments. Anything I do to a no-NAND unit, by contrast, can never persist beyond power-off. Pull the SD card, plug a different SD card, fresh state. For experimenting with new U-Boot builds or DT changes, that is significantly safer.

**No FEL is needed on either unit.** This was the original goal — boot Linux from cold, no laptop attached, no USB sideload — and now it's true for both machines I have.

## What this rules out

This post does *not* prove that the recipe works on every Remix Mini PC ever sold. There are likely small variations across production runs that I cannot test from here. The CPU stepping, the DDR3 supplier, the exact WiFi module — any of these could differ on someone else's unit and require small tweaks to the defconfig or DTB. The vqmmc-supply patch we did on the bananapi DTB, for example, is a Remix-specific addition; the DRAM clock and ZQ values in the upstream defconfig may not match every unit either.

What this post does prove is that the *two* units I have, despite one of them having a different hardware population, take the same SD card. That's a useful data point for anyone considering the recipe.

## What I am keeping the no-NAND unit for

This used to be a paperweight. As of this evening, it is a perfectly good 2 GB ARM Linux box that boots from a single SD card and runs unattended. It will probably end up as a permanent home for something — a small monitoring node, a development sandbox for the next project, maybe just a second machine to keep on a shelf for friends who want to see the recipe work in person.

It is good to have the option.
