# Remix Mini PC: After a Year of Dead Ends, the eMMC Finally Talks

For more than a year I have been chasing the same brick wall on the Remix Mini PC project: I could sideload a working Linux from an SD card, but the internal eMMC was a black box. Every attempt to read from it returned an I/O error. Every theory I tried — write-protect bits, NAND blacklists, hardware reset quirks, lockout states left behind by Android — went nowhere.

It turns out the cause was none of those things. It was one missing line in a device tree.

## The setup recap

The Remix Mini PC is a 2015-vintage Android desktop box built around an Allwinner SoC (marketed as "H64", which is the same silicon as the much more common A64). Stock firmware was a locked Android variant that the manufacturer abandoned long ago. The project's goal: replace it with Armbian, permanently, on the internal eMMC.

The state going into this session:

- FEL mode sideload of mainline U-Boot works (built with the BananaPi-M64 defconfig).
- SD card boot all the way to a login prompt works (Armbian 24.11.1, kernel 6.6.62).
- Reading from the internal eMMC, however, immediately fails with kernel errors:

```
sunxi-mmc 1c11000.mmc: data error, sending stop command
sunxi-mmc 1c11000.mmc: send stop command failed
mmc2: cache flush error -110
mmc2: tried to HW reset card, got error -110
mmcblk2: recovery failed!
```

The kernel sees the chip — it reads its CID, its CSD, its 14.6 GiB capacity, its part name (`AGND3R`) — but the moment the host asks for actual data, the bus collapses.

## Things I tried that did *not* matter

I went deep into the device tree binary. Patching it in place with `fdtput`, decompiling and recompiling with `dtc`. I tested, in order:

| Knob | What I tried | Result |
|---|---|---|
| Bus clock | 150 MHz → 25 MHz → 1 MHz | identical failure |
| Bus modes | disabled HS200, HS400, 1.8V signaling | identical failure |
| Bus width | 8-bit → 4-bit | identical failure |
| HW reset capability | removed `cap-mmc-hw-reset` | identical failure |
| Pin muxing | dropped the HS400 data-strobe pin | identical failure |

The failure mode never changed shape. That was the clue I should have read earlier: if signal-rate tweaks don't move the needle at all, the problem is not at the signal layer.

## The breakthrough

A web search turned up something I had not realised existed: **the Remix Mini PC is supported in mainline Linux**, under the name `sun50i-h64-remix-mini-pc.dts`, contributed by Andre Przywara at ARM. The DTS lives in the mainline kernel tree at `arch/arm64/boot/dts/allwinner/`. The corresponding U-Boot patch landed in April 2024.

I pulled the official Remix DTS and put it side by side with the BananaPi-M64 DTS I had been using. The difference for the eMMC block jumped off the screen:

```dts
&mmc2 {
    pinctrl-names = "default";
    pinctrl-0 = <&mmc2_pins>, <&mmc2_ds_pin>;
    vmmc-supply = <&reg_dcdc1>;     // chip Vcc, 3.3V — was present
    vqmmc-supply = <&reg_eldo1>;    // I/O voltage, 1.8V — WAS MISSING
    bus-width = <8>;
    non-removable;
    mmc-hs200-1_8v;
    mmc-hs400-1_8v;
    cap-mmc-hw-reset;
};
```

The BananaPi-M64 DTB declares only `vmmc-supply`, the regulator that powers the eMMC chip itself. It says nothing about `vqmmc-supply`, the separate regulator that drives the eMMC bus signal lines.

eMMC uses two voltage domains. Vcc (the `vmmc` rail) powers the chip's internal logic. VccQ (the `vqmmc` rail) is the I/O voltage for CLK, CMD, and DAT0–7. On the Remix's PCB, that rail is wired to a different regulator (`eldo1`, 1.8V) than the chip's main supply. Without the kernel knowing about that regulator, it never gets enabled — and the data bus lines have no drive voltage.

That explained everything. The chip's command/response channel runs at different signaling and was already powered, so initialisation worked. The instant the host attempted a data transfer over DAT0–3, the bus collapsed. There was nothing to receive on.

## The fix

I added the missing property to the live DTB on the SD card:

```sh
sudo fdtput -t i /boot/dtb/allwinner/sun50i-a64-bananapi-m64.dtb \
    /soc/mmc@1c11000 vqmmc-supply 0x4e
```

`0x4e` is the phandle of the `eldo1` regulator node in the same DTB, which the BananaPi-M64 board uses for its audio codec but which on the Remix is the eMMC I/O rail. Same regulator hardware; just being repurposed to point at the right consumer.

Reboot. Sideload U-Boot via FEL. Log in. Type the test:

```sh
sudo dd if=/dev/mmcblk2 bs=1M count=1 of=/tmp/test.bin status=progress
```

```
1+0 records in
1+0 records out
1048576 bytes (1,0 MB, 1,0 MiB) copied, 0,0482 s, 21,7 MB/s
```

A megabyte. In fifty milliseconds. From a chip that had not yielded a single readable byte in over a year.

For good measure I queried the EXT_CSD register, which uses a different MMC command path than block reads — that worked too. And it revealed something I had not let myself hope for:

```
BOOT_WP_STATUS:   0x00      // not write-protected
BOOT_WP:          0x00      // not write-protected
USER_WP:          0x00      // not write-protected
BOOT_CONFIG_PROT: 0x00      // boot config can be changed
PARTITION_SETTING_COMPLETED: 0x00
```

The chip is not locked. It has never been locked. The "permanently write-protected" story I had been telling myself based on Linux-level `force_ro` flags and observed I/O errors was wrong. The chip is wide open. I just could not see it because the bus could not carry a single byte.

## Lessons I want to keep

A few things from this session worth holding onto, in case they are useful to anyone else fighting a similar ghost.

**Find the official upstream description of your hardware before you start guessing at it.** The single most valuable artifact in this debugging session was the official `sun50i-h64-remix-mini-pc.dts` file in mainline. Fifteen minutes of reading saved me what would have been days more of DT poking. The fact that the Remix Mini PC has had mainline support since 2023 and I did not know it is on me.

**If a tunable does not change the failure mode, the failure is not in that tunable's layer.** I tried five different knobs across two orders of magnitude in clock speed. None of them moved the symptom. That should have told me immediately that the failure was at a layer below "bus signaling". I kept going because I had no better idea, but in hindsight that was wasted effort.

**Distinguish what the chip says about itself from what the host's view of the chip says.** Linux block-device flags like `force_ro` are software-level safety overlays. The chip's actual write protection lives in the EXT_CSD register and is queryable with `mmc-utils`. Until I could query that register, every claim about whether the chip was "locked" was guesswork. The reason I could not query it earlier was the same vqmmc problem — `mmc extcsd read` also needs a working data bus. The same fix unlocked everything at once.

**Two voltage rails. eMMC always has two voltage rails.** Vcc and VccQ. If you only configure one, the chip will enumerate and then silently refuse all data transfers. This is now permanently lodged in my head.

## What is next

The eMMC being readable is the milestone, but the project's goal is to make the Remix boot Linux from internal storage *without* needing a USB-OTG FEL trigger every time. That is a separate problem — the Allwinner A64 boot ROM on this board enforces a particular signed-image format called TOC0, which standard sunxi U-Boot does not produce by default. There is a mainline U-Boot defconfig (`remix-mini-pc_defconfig`) that does, and writing a TOC0-wrapped SPL into the eMMC boot partition should give us a cold-boot path.

That's the next post.

For now: after more than a year, the device that I had been treating as half-dead has its biggest organ back. Onward.
