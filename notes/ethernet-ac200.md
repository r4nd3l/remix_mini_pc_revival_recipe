# Wired Ethernet on the Remix Mini PC — where it stands (2026-10-13)

Board: Jide Remix Mini PC (Allwinner H64 = A64), Armbian 26.5.1, kernel 6.18.33-current-sunxi64,
`fdtfile=allwinner/sun50i-h64-remix-mini-pc.dtb`, user overlay `overlays/ac200-eth.dtbo`.

## Symptom

No `eth0`. The EMAC driver gives up at boot, and the same when re-bound by hand later:

```
dwmac-sun8i 1c30000.ethernet: EMAC reset timeout
dwmac-sun8i 1c30000.ethernet: probe with driver dwmac-sun8i failed with error -110
```

## What works

- The AC200 answers on I2C (`i2c0`, address 0x10); `ac200-ephy-ctl` binds.
- The EPHY rails come up (`vcc-ephy-2v5`, `vcc-ephy-1v8`, `vcc-ephy-1v2`).

## What does not — the likely cause

The overlay feeds the AC200 from

```
ac200-clk { compatible = "fixed-clock"; clock-frequency = <24000000>; };
```

A `fixed-clock` only *tells* Linux a 24 MHz clock exists; nothing on the board is made to produce it.
On other AC200 boards (H6 TV boxes) that clock comes from a SoC **PWM output** driven at 24 MHz.
On this unit no PWM device is enabled at all (`/sys/bus/platform/devices` has none), so the
EPHY most likely has no clock, gives the MAC no RX clock, and the MAC's soft reset never completes —
which is exactly what "EMAC reset timeout" means. Re-binding later (probe-order theory) fails the
same way, which rules that theory out.

## Next experiment

1. Find which pin feeds the AC200 clock on this board (original Android `script.bin`/FEX, or the
   board photos: trace from the AC200's 24M input). Candidate: A64 `PWM0` on **PD22** — note the
   overlay currently claims PD22 for `emac` in `mii-pins`; plain MII does not need all of PD8–PD23.
2. Overlay: enable `&pwm`, give PD22 to `pwm0`, and replace `ac200-clk` with a `pwm-clock`
   (`compatible = "pwm-clock"; pwms = <&pwm 0 42 0>;` → 41.67 ns ≈ 24 MHz).
3. Reboot, check `dmesg | grep -i -E "ac200|dwmac|eth0"`.

A failed overlay does not stop the boot (U-Boot skips it); FEL recovery stays possible regardless.

## Meanwhile

A USB Ethernet adapter (RTL8152/8153 or AX88179 — mainline drivers) gives a wired link today and
lets the staging `r8723bs` Wi-Fi driver be switched off, which is the prime suspect for the freezes
(2026-10-11 link drops, 2026-10-12 and 2026-10-13 hard freezes).
