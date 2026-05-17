#!/usr/bin/env python3
"""Generate an RP1 overclock device-tree overlay (.dts → dtc → .dtbo) for the
running kernel, using its own rp1.h binding header + the live device tree.

Why a generator rather than a static .dtso per kernel: the order of the
`assigned-clock-rates` array depends on the order of `assigned-clocks`, which
is set by the kernel's rp1 driver and uses RP1 clock IDs from
`<dt-bindings/clock/rp1.h>`. Those IDs are stable within a kernel series but
have shifted in the past (the array we observe on kernel 6.12 lists 13
entries; older series listed fewer). Hand-writing one .dtso per series is
maintenance-heavy and easy to get wrong; this script reads both sources of
truth fresh every install.

Inputs:
    --target HZ     Target rate for RP1_PLL_SYS / RP1_CLK_SYS (default
                    333333333 = pll_sys_core / 3). Must be on the PLL grid,
                    i.e. exact pll_sys_core / N for integer N>=1, or the
                    kernel will snap.
    --pll-sys-core  Optional override for the assumed PLL_SYS_CORE rate
                    (default reads it from the live DT array).
    --headers DIR   Override the linux-headers search root.
    --kernel REL    Use a specific kernel release for header lookup
                    (default = `uname -r`).
    --out PATH      Output path for the compiled .dtbo (required).
    --keep-dts      Keep the generated .dts alongside the .dtbo for
                    inspection / debugging.
    --dry-run       Print the generated .dts to stdout and exit.

Exit codes:
    0   success
    2   kernel headers missing or rp1.h not found
    3   live device tree path missing (not running on a Pi 5)
    4   clock-ID parsing failed
    5   dtc not available or compile failed
    6   target rate not on the PLL grid

The generated overlay re-specifies the full assigned-clock-rates array
exactly as the kernel currently has it, modifying only the RP1_PLL_SYS and
RP1_CLK_SYS entries to the target rate. All other clocks (audio, sdio, eth,
etc.) keep their current rates so nothing else moves.
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

DT_RP1_CLOCKS_DIR_DEFAULT = Path(
    "/sys/firmware/devicetree/base/axi/pcie@1000120000/rp1/clocks@18000"
)
# Allow tests / CI to point at a fixture directory containing
# {assigned-clocks, assigned-clock-rates} binary blobs.
DT_RP1_CLOCKS_DIR = Path(
    os.environ.get("RP1_OVERCLOCK_DT_BASE", str(DT_RP1_CLOCKS_DIR_DEFAULT))
)
HEADERS_BASE_DEFAULT = Path("/usr/src")


def die(code: int, msg: str) -> "NoReturn":
    print(f"generate_dtbo.py: {msg}", file=sys.stderr)
    sys.exit(code)


def find_rp1_header(kver: str, headers_base: Path) -> Path:
    """Locate dt-bindings/clock/rp1.h for the given kernel release."""
    # Pi OS ships headers in linux-headers-<rel>+rpt-common-rpi (common
    # arch-independent headers) — that's where the dt-bindings live.
    candidates = [
        headers_base / f"linux-headers-{kver}" / "include" / "dt-bindings" / "clock" / "rp1.h",
    ]
    # Try every "*common*" directory matching the kernel series too.
    series_prefix = ".".join(kver.split(".", 2)[:2])  # "6.12"
    for entry in sorted(headers_base.glob(f"linux-headers-{kver}*")):
        candidates.append(entry / "include" / "dt-bindings" / "clock" / "rp1.h")
    for entry in sorted(headers_base.glob(f"linux-headers-{series_prefix}.*common*")):
        candidates.append(entry / "include" / "dt-bindings" / "clock" / "rp1.h")
    for entry in sorted(headers_base.glob(f"linux-headers-{series_prefix}*")):
        candidates.append(entry / "include" / "dt-bindings" / "clock" / "rp1.h")
    for p in candidates:
        if p.is_file():
            return p
    die(
        2,
        f"could not find dt-bindings/clock/rp1.h under {headers_base} for "
        f"kernel {kver}. Install linux-headers-{kver}+rpt-common-rpi "
        f"(or equivalent), or pass --headers DIR.",
    )


# Names whose presence is REQUIRED for the overclock target. Other clock
# names from rp1.h are also useful for logging / sanity checks.
REQUIRED_NAMES = ("RP1_PLL_SYS_CORE", "RP1_PLL_SYS", "RP1_CLK_SYS")


def parse_rp1_header(path: Path) -> dict[str, int]:
    """Return {name: clock_id} for every RP1_* define in rp1.h."""
    text = path.read_text()
    out: dict[str, int] = {}
    for m in re.finditer(r"^\s*#\s*define\s+(RP1_[A-Z0-9_]+)\s+(\d+)\s*$", text, re.M):
        out[m.group(1)] = int(m.group(2))
    missing = [n for n in REQUIRED_NAMES if n not in out]
    if missing:
        die(4, f"rp1.h at {path} missing defines: {missing}")
    return out


def read_be_u32_array(p: Path) -> list[int]:
    raw = p.read_bytes()
    if len(raw) % 4:
        die(3, f"{p}: size {len(raw)} not a multiple of 4")
    return list(struct.unpack(f">{len(raw)//4}I", raw))


def read_assigned_clocks() -> tuple[list[int], list[int]]:
    """Return (slot_phandles, slot_clock_ids) for the rp1_clocks assigned-clocks
    array (paired u32s). Returns ([], []) if the file is missing."""
    p = DT_RP1_CLOCKS_DIR / "assigned-clocks"
    if not p.is_file():
        die(3, f"{p} missing — are we on a Pi 5 with the rp1 driver?")
    arr = read_be_u32_array(p)
    if len(arr) % 2:
        die(3, f"{p}: odd number of u32 entries ({len(arr)})")
    return arr[0::2], arr[1::2]


def read_assigned_clock_rates() -> list[int]:
    p = DT_RP1_CLOCKS_DIR / "assigned-clock-rates"
    if not p.is_file():
        die(3, f"{p} missing — are we on a Pi 5 with the rp1 driver?")
    return read_be_u32_array(p)


def find_slot(clock_ids: list[int], target_id: int, name: str) -> int:
    try:
        return clock_ids.index(target_id)
    except ValueError:
        die(
            4,
            f"clock id for {name}={target_id} not found in live assigned-clocks "
            f"(slots: {clock_ids}). The kernel may not assign this clock by "
            f"default, in which case the overlay would need to ADD it rather "
            f"than re-specify a slot — out of scope for this generator.",
        )


def check_pll_grid(target_hz: int, pll_sys_core_hz: int) -> int:
    """Confirm target_hz lies on pll_sys_core / N. Returns the divider N."""
    if target_hz <= 0:
        die(6, "target rate must be positive")
    if pll_sys_core_hz <= 0:
        die(6, f"pll_sys_core rate must be positive, got {pll_sys_core_hz}")
    # Clamp N to >=1: a target above pll_sys_core would otherwise round to 0
    # and trip ZeroDivisionError below.
    n = max(1, round(pll_sys_core_hz / target_hz))
    achieved = pll_sys_core_hz // n
    if abs(achieved - target_hz) > 1:
        # Off-grid: tell the user the nearest achievable rates.
        below_n = n + 1
        above_n = max(1, n - 1)
        die(
            6,
            f"target {target_hz} Hz isn't on the PLL grid. Nearest achievable: "
            f"{pll_sys_core_hz // n} Hz (N={n}). Other options: "
            f"{pll_sys_core_hz // above_n} (N={above_n}), "
            f"{pll_sys_core_hz // below_n} (N={below_n}). The kernel would snap "
            f"anyway; pick an exact grid value.",
        )
    return n


# Build a human-readable comment column. ids → names from the rp1.h dump.
def name_for_id(ids_to_names: dict[int, str], cid: int) -> str:
    return ids_to_names.get(cid, f"id={cid}")


def emit_dts(
    *,
    target_hz: int,
    rates: list[int],
    pll_sys_slot: int,
    clk_sys_slot: int,
    ids: list[int],
    ids_to_names: dict[int, str],
    n_divider: int,
    pll_sys_core_hz: int,
    kver: str,
) -> str:
    """Render the .dts text for the overlay."""
    lines = [
        "/dts-v1/;",
        "/plugin/;",
        "",
        "/*",
        f" * Generated by rp1-overclock-tool generate_dtbo.py",
        f" * Source kernel: {kver}",
        f" * pll_sys_core = {pll_sys_core_hz} Hz (slot 0)",
        f" * Target: RP1_PLL_SYS + RP1_CLK_SYS = pll_sys_core / {n_divider}",
        f" *         = {target_hz} Hz (= {target_hz / 1e6:.3f} MHz)",
        " *",
        " * All non-target slots are pinned to the values the live kernel",
        " * already programmed, so nothing else moves.",
        " */",
        "",
        "/ {",
        '\tcompatible = "brcm,bcm2712";',
        "\tfragment@0 {",
        "\t\ttarget = <&rp1_clocks>;",
        "\t\t__overlay__ {",
        "\t\t\tassigned-clock-rates = <",
    ]
    new_rates = list(rates)
    new_rates[pll_sys_slot] = target_hz
    new_rates[clk_sys_slot] = target_hz
    for i, hz in enumerate(new_rates):
        name = name_for_id(ids_to_names, ids[i])
        marker = " [TARGET]" if i in (pll_sys_slot, clk_sys_slot) else ""
        lines.append(f"\t\t\t\t/* {name:<24}{marker} */ {hz}")
    lines.append("\t\t\t>;")
    lines.append("\t\t};")
    lines.append("\t};")
    lines.append("};")
    return "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--target", type=int, default=333333333,
                    help="RP1_PLL_SYS / RP1_CLK_SYS target rate in Hz "
                         "(default 333333333 = pll_sys_core/3)")
    ap.add_argument("--pll-sys-core", type=int, default=0,
                    help="Override PLL_SYS_CORE rate in Hz (default: read "
                         "from live DT slot 0)")
    ap.add_argument("--kernel", default=os.uname().release,
                    help="Kernel release string for header lookup")
    ap.add_argument("--headers", type=Path, default=HEADERS_BASE_DEFAULT,
                    help="linux-headers search root")
    ap.add_argument("--out", type=Path, required=True,
                    help="Output .dtbo path")
    ap.add_argument("--keep-dts", action="store_true",
                    help="Write the generated .dts alongside .dtbo")
    ap.add_argument("--dry-run", action="store_true",
                    help="Print .dts to stdout and exit, don't compile")
    args = ap.parse_args()

    header = find_rp1_header(args.kernel, args.headers)
    name_to_id = parse_rp1_header(header)
    id_to_name = {v: k for k, v in name_to_id.items()}

    _, clock_ids = read_assigned_clocks()
    rates = read_assigned_clock_rates()
    if len(rates) != len(clock_ids):
        die(
            3,
            f"DT mismatch: {len(clock_ids)} assigned-clocks vs "
            f"{len(rates)} assigned-clock-rates",
        )

    pll_sys_slot = find_slot(clock_ids, name_to_id["RP1_PLL_SYS"], "RP1_PLL_SYS")
    clk_sys_slot = find_slot(clock_ids, name_to_id["RP1_CLK_SYS"], "RP1_CLK_SYS")
    pll_sys_core_hz = args.pll_sys_core or rates[
        find_slot(clock_ids, name_to_id["RP1_PLL_SYS_CORE"], "RP1_PLL_SYS_CORE")
    ]

    n_divider = check_pll_grid(args.target, pll_sys_core_hz)

    dts = emit_dts(
        target_hz=args.target,
        rates=rates,
        pll_sys_slot=pll_sys_slot,
        clk_sys_slot=clk_sys_slot,
        ids=clock_ids,
        ids_to_names=id_to_name,
        n_divider=n_divider,
        pll_sys_core_hz=pll_sys_core_hz,
        kver=args.kernel,
    )

    print(
        f"detected kernel {args.kernel}, rp1.h={header}",
        file=sys.stderr,
    )
    print(
        f"RP1_PLL_SYS at slot {pll_sys_slot}, RP1_CLK_SYS at slot {clk_sys_slot}; "
        f"pll_sys_core={pll_sys_core_hz} Hz; target={args.target} Hz "
        f"(pll_sys_core/{n_divider})",
        file=sys.stderr,
    )

    if args.dry_run:
        sys.stdout.write(dts)
        return 0

    if not shutil.which("dtc"):
        die(5, "dtc not in PATH. Install with: sudo apt install device-tree-compiler")

    out: Path = args.out
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rp1-overclock-") as tmp:
        dts_path = Path(tmp) / "overlay.dts"
        dts_path.write_text(dts)
        if args.keep_dts:
            sidecar = out.with_suffix(".dts")
            sidecar.write_text(dts)
            print(f"wrote {sidecar}", file=sys.stderr)
        cmd = ["dtc", "-@", "-I", "dts", "-O", "dtb", "-o", str(out), str(dts_path)]
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode != 0:
            die(5, f"dtc failed:\n{res.stderr}")
    print(f"wrote {out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
