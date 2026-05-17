#!/usr/bin/env bash
# Fixture-driven smoke test for generate_dtbo.py.
#
# Runs the generator against tests/fixtures/{dt,headers}, comparing the
# emitted .dts against a golden snapshot. Designed for CI runners that
# don't have a real Pi 5 underneath them.
#
# Usage:
#   ./tests/run_tests.sh                  # check against golden
#   ./tests/run_tests.sh --update-golden  # rewrite the golden file
#
# Pass criteria:
#   - generator exits 0
#   - the printed .dts equals tests/fixtures/golden.dts byte-for-byte
#   - the off-grid target test exits non-zero with an instructive message

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GEN="$ROOT/generate_dtbo.py"
DT="$HERE/fixtures/dt"
HEADERS="$HERE/fixtures/headers"
GOLDEN="$HERE/fixtures/golden.dts"
KVER="6.99.0-fixture+rpt-common-rpi"

UPDATE=0
if [[ "${1:-}" == "--update-golden" ]]; then UPDATE=1; fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "[test] on-grid 333 MHz target..."
RP1_OVERCLOCK_DT_BASE="$DT" "$GEN" \
    --kernel "$KVER" \
    --headers "$HEADERS" \
    --target 333333333 \
    --out "$tmp/out.dtbo" \
    --dry-run > "$tmp/generated.dts"

if [[ $UPDATE -eq 1 ]]; then
    cp "$tmp/generated.dts" "$GOLDEN"
    echo "  golden updated: $GOLDEN"
else
    if ! diff -u "$GOLDEN" "$tmp/generated.dts"; then
        echo "[test] FAIL: generated .dts differs from golden" >&2
        exit 1
    fi
    echo "  ok: matches golden"
fi

echo "[test] off-grid target should be rejected..."
if RP1_OVERCLOCK_DT_BASE="$DT" "$GEN" \
        --kernel "$KVER" \
        --headers "$HEADERS" \
        --target 311111111 \
        --out "$tmp/out.dtbo" \
        --dry-run > "$tmp/badrun.out" 2> "$tmp/badrun.err"; then
    echo "[test] FAIL: off-grid target was accepted" >&2
    cat "$tmp/badrun.err" >&2
    exit 1
fi
if ! grep -q "isn't on the PLL grid" "$tmp/badrun.err"; then
    echo "[test] FAIL: off-grid error message missing expected text" >&2
    cat "$tmp/badrun.err" >&2
    exit 1
fi
echo "  ok: off-grid target rejected with the expected message"

echo "[test] target above pll_sys_core should be rejected, not crash..."
if RP1_OVERCLOCK_DT_BASE="$DT" "$GEN" \
        --kernel "$KVER" \
        --headers "$HEADERS" \
        --target 2000000000 \
        --out "$tmp/out.dtbo" \
        --dry-run > "$tmp/highrun.out" 2> "$tmp/highrun.err"; then
    echo "[test] FAIL: target > pll_sys_core was accepted" >&2
    exit 1
fi
if grep -qi "traceback\|zerodivision" "$tmp/highrun.err"; then
    echo "[test] FAIL: target > pll_sys_core crashed instead of erroring cleanly" >&2
    cat "$tmp/highrun.err" >&2
    exit 1
fi
echo "  ok: high target rejected cleanly"

echo "[test] all green."
