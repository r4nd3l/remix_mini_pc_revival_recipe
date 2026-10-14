# Wired Ethernet on the Remix Mini PC (AC200): status as of 2026-10-13

Board: Jide Remix Mini PC (Allwinner H64 = A64), Armbian 26.5.1, kernel 6.18.33-current-sunxi64,
`fdtfile=allwinner/sun50i-h64-remix-mini-pc.dtb`, user overlay `ac200-eth`.

## The symptom

```
dwmac-sun8i 1c30000.ethernet: EMAC reset timeout
dwmac-sun8i 1c30000.ethernet: probe with driver dwmac-sun8i failed with error -110
```

## What the registers say

The AC200 sits on i2c0 at 0x10. It is big-endian on the wire, and it is paged through
register 0xfe. Read it with `i2cget -f -y 1 0x10 <reg> w`, then swap the bytes. The kernel regmap
caches the page selector, so restore 0xfe after poking at it. The cleanest way to read is root
`cat /sys/kernel/debug/regmap/1-0010-AC200/registers`.

| reg | value | meaning |
|---|---|---|
| 0x0000 | 0101 | chip id: the AC200 answers |
| 0x0008 SYS_CLK_CTL | 0007 | CKI_24M input enabled; SYS_CLK comes from the pin |
| 0x6000 EPHY_CTL | 3014 | MII, PHY address 1, 24 MHz, powered up (SHUTDOWN = 0) |
| **0x0014 SYS_EPHY_CTL0** | **0000** | **EPHY clock gated off and held in reset** |

The 24 MHz reference arrives: the AC200 has no 24 MHz oscillator of its own (datasheet
§9.5.5), so something on the board feeds CKI_24M. The `fixed-clock` in the v1 overlay is
therefore not a lie. What is missing is the gate: SYS_EPHY_CTL0.

## The experiments

1. `SYS_EPHY_CTL0 = 0x0003` by hand, then re-bind the EMAC. **The link comes up:
   `Link is Up - 100Mbps/Full`.** The PHY works and sees the cable.
2. phylib then put the PHY back into reset (0x0014 read 0x0002 afterwards). The v1 overlay gives
   the PHY node `resets`/`clocks` pointing at `ac200-ephy-ctl`, and an unattached PHY is held in
   reset. This also makes the ID read fail, so it binds as "Generic PHY".
3. **v2 overlay** (`overlays/ac200-eth-v2.dts`): the PHY node has no `resets`/`clocks` and is
   matched by id (`ethernet-phy-id0044.1400`). `system/cs-ac200-eth.sh` (a boot oneshot) loads
   the AC200 modules, sets SYS_EPHY_CTL0 = 0x0003 and binds the EMAC. After a reboot,
   0x0014 stays at 0003.
4. It still fails. `dwmac-sun8i` (v6.18, `sun8i_dwmac_probe`) ends with `sun8i_dwmac_reset()`
   for an external PHY. That reset needs the MII RX/TX clocks from the PHY at that moment.
   The PHY has not been attached or resumed through MDIO yet; that only happens on `open`, so
   its clocks are most likely still off (BMCR power-down?). When networkd opens the interface
   during the probe, the link comes up, but by then the probe's 100 ms reset poll has already
   lost the race.

5. **v3 overlay** (`overlays/ac200-eth-v3.dts`): RMII instead of MII (EPHY_CTL = 3814). Same
   probe-time reset timeout.
6. Do **not** poke CCU/syscon/EMAC registers through `/dev/mem` to test this: one such probe
   froze the board hard (power cycle needed).

## The fix: a one-line kernel patch

`kernel/cs-dwmac-sun8i-tolerate-probe-reset.patch`: with an external PHY, a failed probe-time
reset only warns instead of tearing the device down. The MAC is set up again on open, when the
PHY is attached and clocking. Built with the Armbian framework at tag v26.5.1:

```
cp kernel/cs-dwmac-sun8i-tolerate-probe-reset.patch <armbian-build>/userpatches/kernel/archive/sunxi-6.18/
./compile.sh kernel BOARD=pine64 BRANCH=current KERNELBRANCH=tag:v6.18.33 KERNEL_CONFIGURE=no
```

Install the `linux-image-current-sunxi64` and `linux-dtb-current-sunxi64` debs from `output/debs`,
then `apt-mark hold` both so an Armbian update does not drop the patch.

## Result with the patched kernel (2026-10-14): the clock never reaches the MAC

The probe survives, the PHY binds as `Allwinner AC200 EPHY`, and `Link is Up - 100Mbps/Full`.
But RX stays at 0 packets and TX hits `NETDEV WATCHDOG ... transmit queue 0 timed out`.
`ethtool -d eth0 raw on` shows EMAC_BASIC_CTL1 = 0x08000001: the soft-reset bit never clears,
so the MAC gets no RX/TX clock from the PHY. Everything below was tried, and all of it gave the same result:

- RMII (syscon 0x30 = 0x2001) and MII;
- AC200 CLK_SEL for 24 MHz and for 25 MHz, including an EPHY reset pulse after the switch;
- pinmux: PD10-PD23 are all on `emac` (pinctrl debugfs).

The AC200 side matches the working H6 boxes (SYS_EPHY_CTL0 = 0003, SYS_EPHY_CTL1 = 000f with MII IO
enabled). Getting further needs the schematic or a scope on PD19 (ETXCK). The factory config was in
neither the eMMC dumps nor anywhere online.

**Decision:** use a USB Ethernet adapter (RTL8153). The onboard port is kept down with
`system/05-cs-eth0-off.network` (in `/etc/systemd/network/`), and `cs-ac200-eth.service` is disabled.
Otherwise the TX watchdog resets the adapter every ~6 s. The patched kernel stays installed and held.

Also seen: a warm `systemctl reboot` hung after "Journal stopped", and only a power cycle brought
the board back. Do not reboot remotely.

## Older options

- A small out-of-tree module, or a one-line kernel patch, to clear BMCR power-down
  over MDIO before the probe-time reset, or to retry that reset after the PHY is attached.
- Find out whether the AC200 EPHY powers up with BMCR.PDOWN set, and whether an AC200
  register forces it. Datasheet §9.11 (EPHY) does not show it.
- Meanwhile: a USB Ethernet adapter (RTL8153/AX88179, mainline drivers).

## Done in this round (also on the device)

- Wi-Fi: `system/r8723bs.conf`. `rtw_ips_mode=0` turns off inactive power save, a known source
  of r8723bs drop-outs and hangs. `rtw_power_mgnt=0` was already set.
- Cooling: `system/cpu-governor.tmpfiles.conf` sets `schedutil` instead of `performance`
  pinned at 1008 MHz. Idle went from 63 °C to about 53 °C. Trip points: 70 passive / 80 hot /
  90 critical.
- Logs: `system/journald-persistent.conf`, plus `ENABLED=false` in `/etc/default/armbian-ramlog`,
  so the journal survives a freeze or a reboot. Before this, the last hours before each freeze
  were lost.
