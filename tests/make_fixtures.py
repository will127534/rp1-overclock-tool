#!/usr/bin/env python3
"""Re-generate the binary DT fixtures used by tests/run_tests.sh.

The fixtures mimic a real Pi 5 6.12 kernel's rp1_clocks/assigned-clocks +
assigned-clock-rates arrays. Captured from a live Pi 5 8GB on kernel
6.12.75+rpt-rpi-2712 in May 2026 (chip_id 0x20001927, BCM2712 C0).

Run once after editing this file; commit the resulting binary blobs.
"""
import struct
from pathlib import Path

HERE = Path(__file__).resolve().parent
DT_DIR = HERE / "fixtures" / "dt"

# (phandle, clock_id) pairs — phandle is irrelevant to the generator, only
# the clock-id half is consulted. We keep the captured values for realism.
ASSIGNED_CLOCKS_PAIRS = [
    (0x00000002, 0x00),  # RP1_PLL_SYS_CORE
    (0x00000002, 0x01),  # RP1_PLL_AUDIO_CORE
    (0x00000002, 0x03),  # RP1_PLL_SYS
    (0x00000002, 0x09),  # RP1_PLL_SYS_SEC
    (0x00000002, 0x10),  # RP1_CLK_ETH
    (0x00000002, 0x04),  # RP1_PLL_AUDIO
    (0x00000002, 0x0a),  # RP1_PLL_AUDIO_SEC
    (0x00000002, 0x0c),  # RP1_CLK_SYS
    (0x00000002, 0x06),  # RP1_PLL_SYS_PRI_PH
    (0x00000002, 0x0d),  # RP1_CLK_SLOW_SYS
    (0x00000002, 0x1f),  # RP1_CLK_SDIO_TIMER
    (0x00000002, 0x20),  # RP1_CLK_SDIO_ALT_SRC
    (0x00000002, 0x1d),  # RP1_CLK_ETH_TSU
]

ASSIGNED_RATES = [
    0x3b9aca00,  # 1_000_000_000 — pll_sys_core
    0x5b8d8000,  # 1_536_000_000 — pll_audio_core
    0x13de4355,  #   333_333_333 — pll_sys
    0x07735940,  #   125_000_000 — pll_sys_sec
    0x07735940,  #   125_000_000 — clk_eth
    0x03a98000,  #    61_440_000 — pll_audio
    0x0927c000,  #   153_600_000 — pll_audio_sec
    0x13de4355,  #   333_333_333 — clk_sys
    0x05f5e100,  #   100_000_000 — pll_sys_pri_ph
    0x02faf080,  #    50_000_000 — clk_slow_sys
    0x000f4240,  #     1_000_000 — clk_sdio_timer
    0x0bebc200,  #   200_000_000 — clk_sdio_alt_src
    0x02faf080,  #    50_000_000 — clk_eth_tsu
]


def main() -> None:
    DT_DIR.mkdir(parents=True, exist_ok=True)
    ac_blob = b"".join(struct.pack(">II", ph, cid) for ph, cid in ASSIGNED_CLOCKS_PAIRS)
    rate_blob = b"".join(struct.pack(">I", r) for r in ASSIGNED_RATES)
    (DT_DIR / "assigned-clocks").write_bytes(ac_blob)
    (DT_DIR / "assigned-clock-rates").write_bytes(rate_blob)
    print(f"wrote {DT_DIR}/assigned-clocks       ({len(ac_blob)} bytes)")
    print(f"wrote {DT_DIR}/assigned-clock-rates  ({len(rate_blob)} bytes)")


if __name__ == "__main__":
    main()
