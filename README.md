# rp1-overclock-tool

Pi 5 RP1 overclock device-tree overlay installer.

The Pi 5's RP1 I/O chip drives the CSI2 receiver and the path to the PiSP
front-end. The CSI2→FE pixel-rate ceiling is `2 × RP1_CLK_SYS − 20 Mpix/s`
(per-scanline overhead), so at the stock 200 MHz it caps at 380 Mpix/s.
Bumping `RP1_PLL_SYS` / `RP1_CLK_SYS` to 300 MHz (which the PLL snaps to
~333.33 MHz) lifts the cap to ~647 Mpix/s. On modes that were
throughput-limited at stock — e.g. IMX294 full-resolution 8432×5648
SRGGB12 — this unlocks the sensor's native framerate (7.87 → 10.5 fps).

This tool keeps the overlay separate from libcamera because the .dtso
encodes the *index* of `RP1_CLK_SYS` in the `rp1_clocks`
`assigned-clock-rates` array, and that index is determined by the running
kernel's `dt-bindings/clock/rp1.h`. If a future kernel renumbers the
bindings, the old overlay would clock the wrong domain. The tool refuses
to install if it doesn't have an overlay matching the running kernel
series.

## Install

```sh
git clone <this repo>
cd rp1-overclock-tool
./install.sh                 # compile + install .dtbo only
./install.sh --apply-config  # also append dtoverlay= line to config.txt
sudo reboot
```

After reboot, verify the clock landed:

```sh
cat /sys/kernel/debug/clk/clk_sys/clk_rate    # expect 333333333
```

And that libcamera picks up the new cap:

```sh
LIBCAMERA_LOG_LEVELS=RPiController:1 rpicam-hello --list-cameras 2>&1 \
    | grep RP1_CLK_SYS
# RP1_CLK_SYS=333333333 Hz [debugfs clk framework]; PiSP pixel-rate cap = 646.667 Mpix/s
```

## Uninstall

```sh
./uninstall.sh --apply-config
sudo reboot
```

## Adding an overlay for a different kernel series

`install.sh` looks for `overlays/rp1-300mhz-kernel<MAJOR>.<MINOR>.dtso`
(e.g. `rp1-300mhz-kernel6.12.dtso`). To add a new kernel:

1. Read your kernel's `include/dt-bindings/clock/rp1.h` to find the index
   of `RP1_CLK_SYS` (and `RP1_PLL_SYS`) in `assigned-clock-rates`.
2. Copy `overlays/rp1-300mhz-kernel6.12.dtso` to a new
   `overlays/rp1-300mhz-kernel<MAJOR>.<MINOR>.dtso`.
3. Adjust the `assigned-clock-rates` array so the right two indices hold
   `300000000`.
4. Re-run `./install.sh`.

## Caveats

- Overclocking the RP1 isn't officially sanctioned by Raspberry Pi. Heat,
  stability, and longevity are at your own risk. Confirmed stable on a
  Pi 5 8GB at room temperature with the official active cooler.
- The 300 MHz target is what the .dtso requests; the PLL divider snaps to
  333.33 MHz. Adjust the .dtso if you want a different target.
- The overlay only affects RP1 clocks. CPU / GPU clocks are unchanged.
- After uninstall + reboot, libcamera reverts to the stock 380 Mpix/s
  cap automatically — no library rebuild needed.
