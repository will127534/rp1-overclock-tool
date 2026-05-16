# rp1-overclock-tool

Pi 5 RP1 overclock device-tree overlay installer.

The Pi 5's RP1 I/O chip drives the CSI2 receiver and the path to the PiSP
front-end. The CSI2→FE pixel-rate ceiling is `2 × RP1_CLK_SYS − 20 Mpix/s`
(per-scanline overhead), so at the stock 200 MHz it caps at 380 Mpix/s.

The RP1 PLL_SYS only produces rates on the grid `pll_sys_core / N` where
`pll_sys_core = 1 GHz` is fixed and `N` is an integer ≥ 1. The first grid
point above stock 200 MHz (N=5) is **333.33 MHz** (N=3) — this overlay
asks for exactly that, so the rate the kernel ends up programming matches
the rate in the device tree. The pixel-rate ceiling rises to ~647 Mpix/s,
unlocking the sensor's native framerate on previously throughput-limited
modes (e.g. IMX294 full-res 8432×5648 SRGGB12: 7.87 → 10.5 fps).

The overlay is shipped here, separate from libcamera, because the .dtso
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
    | grep RP1_PLL_SYS
# RP1_PLL_SYS request=333333333 Hz, snapped to pll_sys_core/3 = 333333333 Hz;
# PiSP pixel-rate cap = 646.667 Mpix/s (2px/clk − 20 overhead)
```

(libcamera reads the requested rate from the live device tree and applies
the PLL snap math itself — no debugfs needed, so this works even when the
running user can't read `/sys/kernel/debug/`.)

## Uninstall

```sh
./uninstall.sh --apply-config
sudo reboot
```

## Adding an overlay for a different kernel series

`install.sh` looks for `overlays/rp1-clk-333mhz-kernel<MAJOR>.<MINOR>.dtso`
(e.g. `rp1-clk-333mhz-kernel6.12.dtso`). To add a new kernel:

1. Read your kernel's `include/dt-bindings/clock/rp1.h` to find the index
   of `RP1_PLL_SYS` and `RP1_CLK_SYS` in `assigned-clock-rates`.
2. Copy the existing kernel6.12 overlay to a new
   `overlays/rp1-clk-333mhz-kernel<MAJOR>.<MINOR>.dtso`.
3. Adjust the `assigned-clock-rates` array so those two indices hold
   `333333333` (and the other entries match your kernel's binding).
4. Re-run `./install.sh`.

## Want a different target rate?

The RP1 PLL_SYS produces only `pll_sys_core / N` rates. Within reasonable
limits the achievable grid points are:

| `N` | rate     | comment                                   |
|-----|----------|-------------------------------------------|
| 5   | 200 MHz  | stock                                     |
| 4   | 250 MHz  | mild bump                                 |
| 3   | 333 MHz  | this overlay — typical sweet spot         |
| 2   | 500 MHz  | aggressive — thermal/stability matters    |

To target a different grid point, copy the .dtso, edit the two
`RP1_PLL_SYS` / `RP1_CLK_SYS` entries to the desired exact `pll_sys_core / N`
value, and re-name the file. Bumping `pll_sys_core` itself is possible too
but riskier; leave it alone unless you know what you're doing.

## Caveats

- Overclocking the RP1 isn't officially sanctioned by Raspberry Pi. Heat,
  stability, and longevity are at your own risk. Confirmed stable on a
  Pi 5 8GB at room temperature with the official active cooler.
- The overlay only affects RP1 clocks. CPU / GPU clocks are unchanged.
- After uninstall + reboot, libcamera reverts to the stock 380 Mpix/s
  cap automatically — no library rebuild needed.
