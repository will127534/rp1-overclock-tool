# Changelog

All notable changes to this project will be documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-05-17

Initial public release. Compiles + installs an RP1 overclock device-tree
overlay (`rp1-clk-333mhz`) for the running Raspberry Pi 5 kernel, raising
the CSI2/PiSP pixel-rate ceiling from ~380 Mpix/s to ~647 Mpix/s.

### Added
- `generate_dtbo.py`: reads the running kernel's
  `<dt-bindings/clock/rp1.h>` and `/sys/firmware/devicetree/base/.../rp1/
  clocks@18000/assigned-clock{,-rates}`, validates that the target rate
  lies on the `pll_sys_core / N` PLL grid, and emits a complete `.dts`
  that re-specifies every slot to its current value while modifying only
  `RP1_PLL_SYS` and `RP1_CLK_SYS`.
- `install.sh`: drives the generator, compiles via `dtc`, installs the
  `.dtbo` (and a `.generated.dts` sidecar) into `/boot/firmware/overlays/`,
  and can optionally append the `dtoverlay=` line to `config.txt`.
- `uninstall.sh`: removes the overlay and optionally scrubs the
  `config.txt` line (with a `.bak` left behind by `sed -i`).
- `--dry-run`, `--apply-config`, `--kernel REL`, and `--target HZ` CLI
  flags on `install.sh`.
- Fixture-driven test harness under `tests/` with a golden `.dts` snapshot
  captured from a Pi 5 8GB on kernel 6.12.75+rpt-rpi-2712.
- GitHub Actions CI: `shellcheck`, `python3 -m py_compile`, and the
  fixture-driven smoke test.

### Changed
- Overlay name standardized as `rp1-clk-333mhz`; the overlay requests
  the exact `pll_sys_core / 3` grid point so the kernel doesn't snap.

### Removed
- The `overlays/` directory and `--bundled` mode that shipped a static
  per-kernel `.dtso`. The generator approach is robust to clock-ID
  renumbering between kernel series, which has happened in the past.

[Unreleased]: https://github.com/CHANGEME/rp1-overclock-tool/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/CHANGEME/rp1-overclock-tool/releases/tag/v0.1.0
