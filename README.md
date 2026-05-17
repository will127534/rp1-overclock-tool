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

The tool is separate from libcamera because the .dtso encodes the *slot
position* of `RP1_CLK_SYS` in the `rp1_clocks` `assigned-clock-rates`
array, and that slot is determined by the running kernel's
`<dt-bindings/clock/rp1.h>` + its rp1 driver's `assigned-clocks` listing.
If a future kernel renumbers the bindings, a hand-written overlay would
clock the wrong domain.

To avoid that risk, `install.sh` doesn't ship a static overlay file at
all. It runs `generate_dtbo.py`, which:

1. Parses the running kernel's `<dt-bindings/clock/rp1.h>` from
   `/usr/src/linux-headers-<rel>+rpt-common-rpi/include/dt-bindings/clock/rp1.h`
   to get the canonical RP1 clock IDs.
2. Reads the live `/sys/firmware/devicetree/base/.../rp1/clocks@18000/`
   to discover which slot of `assigned-clock-rates` corresponds to each
   clock ID and the current rate of every slot.
3. Validates that the requested target rate lies on the PLL grid
   (`pll_sys_core / N` for integer `N`).
4. Generates a complete .dts that re-specifies every slot to its
   current value, modifying only `RP1_PLL_SYS` and `RP1_CLK_SYS`.
5. Compiles with `dtc`, installs the .dtbo + a sidecar
   `.generated.dts` into `/boot/firmware/overlays/`.

Prerequisites:

```sh
sudo apt install linux-headers-rpi-2712 device-tree-compiler
```

## Install

```sh
git clone <this repo>
cd rp1-overclock-tool
./install.sh                              # generate + install for this kernel
./install.sh --apply-config               # also append dtoverlay= line
./install.sh --target 250000000           # different PLL grid point
./install.sh --kernel 6.12.75+rpt-rpi-2712 # cross-install for another release
./install.sh --dry-run                    # show the generated .dts and exit
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

## Running on a new kernel series

Nothing to do — install the matching `linux-headers-<rel>+rpt-common-rpi`
package and run `./install.sh`. The generator reads whatever rp1.h that
kernel ships with and matches it against the running device tree.

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
