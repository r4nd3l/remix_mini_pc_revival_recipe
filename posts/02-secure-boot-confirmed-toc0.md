# Remix Mini PC: Confirming What Stands Between Us and Cold Boot

Now that the eMMC is finally accessible — see the previous post — the project's centre of gravity shifts. The remaining goal is to make the device boot Linux from cold, without needing a USB FEL sideload every time. This post is about a small, quick experiment that pinned down exactly what is in the way.

## What we knew

The Allwinner A64 BROM (the immutable mask-ROM in the SoC) tries to find an SPL in this order:

1. SD card (`mmc0`)
2. eMMC (`mmc2`)
3. SPI NOR flash
4. FEL mode over USB OTG

Up until now my workflow has always been to enter FEL mode and sideload U-Boot from the laptop. That works. But it means the device cannot run headless and standalone — every reboot needs the laptop.

The Linux-sunxi wiki page for the Remix Mini PC has a paragraph that I had read but not really believed:

> The SoC has the "secure boot" fuse burned, so it will not accept any standard eGON boot media on an SD card or eMMC, and instead it expects TOC0 wrapped boot code.

"eGON" is the magic header on standard sunxi SPLs; "TOC0" is a signed-image format with a header structure derived from ARM's Trusted Firmware. The wiki is saying the BROM will refuse anything in the older eGON format.

That sounded inconvenient enough that I wanted to be sure it was true on my specific unit before doing any work that depended on it. Two minutes of testing can save hours of building.

## The experiment

The test is trivial:

1. Boot Armbian normally (via FEL+sideload, as always).
2. From inside Armbian, run `sudo poweroff` and wait for a clean shutdown.
3. Unplug power.
4. Plug power back in. Do nothing else — no FEL trigger, no `sunxi-fel` command, no key on a keyboard.
5. Watch the UART for any sign of life.

If the BROM accepts the SPL on the SD card or the eMMC, U-Boot will start printing within a second or two. If it does not, the device will sit silent — the BROM falls back to FEL mode but FEL mode itself is silent until something talks to it over the OTG port.

I set the SD card to be inserted with a known-working eGON-format SPL on it (the Armbian image's standard layout, dd'd to sector 16). The eMMC boot partition also has an eGON SPL from previous experimentation. If secure boot were not enforced, one of the two should have worked.

## What happened

The power LED came up green. UART stayed completely silent. After fifteen seconds I checked the USB side:

```sh
$ lsusb | grep -i allwinner
Bus 001 Device 010: ID 1f3a:efe8 Allwinner Technology sunxi SoC OTG connector in FEL/flashing mode
```

The board is alive — it is sitting in FEL mode, waiting for a sideload — but it has rejected both candidate SPLs. That is the textbook fingerprint of a BROM with the secure boot eFuse burned and no eGON path accepted.

For completeness, there is no ROTPK (root-of-trust public key) burned into the chip's eFuses either. That second fact matters: it means the BROM enforces the *format* (TOC0) but does not enforce a particular *signing key*. Anyone can sign with any key and the BROM will load it. The TOC0 wrapper is a structural requirement, not a cryptographic one.

## What this rules out, and what it leaves

There were two obvious quick-wins I had been considering for cold-boot, and this test rules out both:

**Option B: zero the existing eMMC SPL and let the BROM fall through to SD.**
The hope here was that the eMMC SPL is what is being chosen first, and if we corrupted it the BROM would skip eMMC and use the SD card's SPL instead. The test shows the SD SPL is *also* being rejected — both are eGON-format, and both fail the BROM's check. Zeroing the eMMC SPL changes nothing.

**Just trusting that eMMC-boot already works because there is an eGON SPL on the eMMC boot partition.**
Looking at the eMMC dump from the previous session, `/dev/mmcblk2boot0` already contained an eGON-format SPL (with a header identifying it as a sunxi mainline build). I had briefly hoped this meant the device might already cold-boot from eMMC. It does not. Same rejection.

What is left, and the only real path forward, is to produce a TOC0-wrapped SPL and write it to either the SD card's sector 16 or the eMMC's boot partition. The mainline U-Boot tree has a defconfig — `remix-mini-pc_defconfig`, added by Andre Przywara — that does exactly this. Build it, sign with any key, write it down, cold-boot.

## A small but useful negative result

The whole exercise took less time than my coffee took to cool down, but it changed the shape of the next chunk of work. Without it I would have been tempted to do something destructive to the eMMC for no benefit. With it I know:

- TOC0 is mandatory. There is no eGON cold-boot path.
- Both the SD and the eMMC are dead ends for standard sunxi binaries — the *medium* is fine, the *format* is the problem.
- FEL remains the only entry point until the day a TOC0-wrapped SPL lives on the device.
- Once we have a working TOC0 SPL, putting it on either the SD card or the eMMC boot partition should produce a working cold-boot. We have two independent shots.

## What's next

Next session: clone mainline U-Boot, build `remix-mini-pc_defconfig`, write the resulting SPL to the eMMC, power-cycle without a laptop attached, and — if the wiki is to be believed — watch the device finally come up on its own.
