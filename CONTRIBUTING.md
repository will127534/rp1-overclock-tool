# Contributing

This is a small (≈300 lines) standalone tool: one Python generator, two
bash drivers. Keep patches the same shape.

## Scope

In scope: anything that improves the reliability of generating the
`rp1-clk-*` overlay across kernel series, packagers, and Pi 5 hardware
revisions.

Out of scope:
- Overclocking anything other than RP1 (no CPU/GPU/voltage tuning).
- A general device-tree-overlay manager.
- Per-distro packaging (Debian rules, RPM specs, AUR). Submit those
  downstream.
- New CLI surface unless an existing flag is genuinely insufficient.

## Adding a kernel-series fix

When a kernel series renumbers the `RP1_*` clock IDs or reshapes the
`assigned-clocks` array, the generator should still work because it reads
the new `rp1.h` and the new DT at install time. If it doesn't:

1. Capture the breakage on the target Pi:
   ```sh
   uname -r
   od -An -tx4 --endian=big \
       /sys/firmware/devicetree/base/axi/pcie@1000120000/rp1/clocks@18000/assigned-clocks
   od -An -tx4 --endian=big \
       /sys/firmware/devicetree/base/axi/pcie@1000120000/rp1/clocks@18000/assigned-clock-rates
   cat /usr/src/linux-headers-$(uname -r | sed 's/+rpt-rpi-.*//')+rpt-common-rpi/include/dt-bindings/clock/rp1.h
   ./install.sh --dry-run 2>&1
   ```
2. Add a fixture under `tests/fixtures/`: copy `tests/make_fixtures.py`
   to a second function (or just edit it) that emits the captured blobs
   into a new subdirectory, and copy the new `rp1.h` into
   `tests/fixtures/headers/linux-headers-<series>+rpt-common-rpi/include/dt-bindings/clock/`.
3. Extend `tests/run_tests.sh` with another invocation pointing at the
   new fixture set, with its own golden `.dts`.
4. Fix `generate_dtbo.py` until the new test passes.

## Testing

Local fast path:

```sh
shellcheck install.sh uninstall.sh tests/run_tests.sh
python3 -m py_compile generate_dtbo.py
./tests/run_tests.sh
```

On a real Pi 5 with `linux-headers` + `device-tree-compiler` installed:

```sh
./install.sh --dry-run                   # inspect the generated .dts
./install.sh                             # actually compile + install
cmp /boot/firmware/overlays/rp1-clk-333mhz.dtbo known-good.dtbo
```

The `--dry-run` mode emits the full `.dts` to stdout and never touches
`/boot/firmware/`, so it's the safe way to inspect what an install would
do on a foreign kernel via `--kernel REL`.

## Code style

- Match the surrounding style. No formatter is enforced.
- Python: type hints where they help, none where they don't. No `mypy`.
- Bash: `set -euo pipefail`, quote every variable expansion that touches
  a path, prefer `[[ ... ]]` over `[ ... ]`.

## Commits

One logical change per commit. Reference the kernel release or RP1
stepping involved in the subject line when relevant — e.g.
`Handle 6.99 assigned-clocks reshape`.
