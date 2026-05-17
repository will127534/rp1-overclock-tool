#!/usr/bin/env bash
# install.sh — compile and install an RP1 overclock dtoverlay for the
# running kernel.
#
# Two modes:
#
#   1. Auto-generate (default). generate_dtbo.py reads the running
#      kernel's <dt-bindings/clock/rp1.h> + the live
#      /sys/firmware/devicetree/base/.../rp1/clocks@18000/{assigned-clocks,
#      assigned-clock-rates} arrays, locates the slots that hold
#      RP1_PLL_SYS and RP1_CLK_SYS, and writes a .dts that re-specifies
#      every slot exactly as the kernel currently has it — moving only
#      those two entries to the target rate. Compiles with dtc.
#      Requires the linux-headers-<rel>+rpt-common-rpi package (or
#      equivalent) so rp1.h is on disk.
#
#   2. Fallback to a bundled per-kernel-series .dtso (overlays/
#      rp1-clk-333mhz-kernel<MAJOR>.<MINOR>.dtso). Used when headers
#      are unavailable. Less flexible — locked to whatever rate the
#      file requests.
#
# Either way the resulting .dtbo lands in /boot/firmware/overlays/ and
# can be enabled by adding `dtoverlay=rp1-clk-333mhz` to config.txt.
#
# Usage:
#   ./install.sh                 auto-generate for the running kernel
#   ./install.sh --target 250000000
#                               auto-generate at a different rate
#                               (must be on the PLL grid: pll_sys_core/N)
#   ./install.sh --bundled       skip auto-generation, use the per-series
#                               .dtso file under overlays/
#   ./install.sh --apply-config  also append `dtoverlay=rp1-clk-333mhz`
#                               to /boot/firmware/config.txt
#   ./install.sh --kernel 6.12.75+rpt-rpi-2712
#                               look up headers for a specific kernel
#                               release (default: `uname -r`)
#   ./install.sh --dry-run       show what would happen, change nothing

set -euo pipefail

OVERLAY_NAME="rp1-clk-333mhz"
BOOT_OVERLAYS_DIR="/boot/firmware/overlays"
CONFIG_TXT="/boot/firmware/config.txt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAYS_SRC_DIR="$SCRIPT_DIR/overlays"
GEN_SCRIPT="$SCRIPT_DIR/generate_dtbo.py"
DEFAULT_TARGET_HZ=333333333

DRY_RUN=0
APPLY_CONFIG=0
MODE="auto"
TARGET_HZ="$DEFAULT_TARGET_HZ"
KVER="$(uname -r)"

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)         usage 0 ;;
        --dry-run)         DRY_RUN=1; shift ;;
        --apply-config)    APPLY_CONFIG=1; shift ;;
        --bundled)         MODE="bundled"; shift ;;
        --kernel)          KVER="$2"; shift 2 ;;
        --target)          TARGET_HZ="$2"; shift 2 ;;
        *)                 echo "unknown arg: $1" >&2; usage 1 ;;
    esac
done

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  [dry-run] $*"
    else
        eval "$@"
    fi
}

if [[ $EUID -ne 0 ]]; then SUDO="sudo"; else SUDO=""; fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
dtbo="$tmpdir/$OVERLAY_NAME.dtbo"

case "$MODE" in
    auto)
        echo "auto-generating overlay for kernel $KVER (target ${TARGET_HZ} Hz)"
        if [[ ! -x "$GEN_SCRIPT" ]]; then
            chmod +x "$GEN_SCRIPT" 2>/dev/null || true
        fi
        gen_args=(--kernel "$KVER" --target "$TARGET_HZ" --out "$dtbo" --keep-dts)
        if [[ $DRY_RUN -eq 1 ]]; then
            # Use --dry-run to print the .dts without compiling. Still want to
            # validate the rp1.h + DT lookup works.
            "$GEN_SCRIPT" "${gen_args[@]}" --dry-run \
                | head -40
            echo "  [...]"
            exit 0
        fi
        "$GEN_SCRIPT" "${gen_args[@]}"
        ;;
    bundled)
        kseries="$(echo "$KVER" | awk -F. '{print $1"."$2}')"
        candidate="$OVERLAYS_SRC_DIR/$OVERLAY_NAME-kernel$kseries.dtso"
        if [[ ! -f "$candidate" ]]; then
            echo "error: no bundled overlay for kernel series $kseries" >&2
            echo "available:" >&2
            ls "$OVERLAYS_SRC_DIR"/*.dtso >&2 || true
            exit 2
        fi
        if ! command -v dtc >/dev/null 2>&1; then
            echo "error: dtc not found. Install device-tree-compiler." >&2
            exit 3
        fi
        echo "using bundled $(basename "$candidate")"
        run "dtc -@ -I dts -O dtb -o \"$dtbo\" \"$candidate\" 2>/dev/null"
        ;;
    *)
        echo "unknown mode: $MODE" >&2; exit 1 ;;
esac

target="$BOOT_OVERLAYS_DIR/$OVERLAY_NAME.dtbo"
echo "installing -> $target"
run "$SUDO install -m 0644 \"$dtbo\" \"$target\""

# Stash the generated .dts next to the .dtbo (auto mode only) so a future
# user can `cat` it to see exactly what the kernel was asked to do.
if [[ "$MODE" == "auto" && -f "${dtbo%.dtbo}.dts" ]]; then
    run "$SUDO install -m 0644 \"${dtbo%.dtbo}.dts\" \"${target%.dtbo}.generated.dts\""
fi

if [[ $APPLY_CONFIG -eq 1 ]]; then
    if grep -qE "^[[:space:]]*dtoverlay[[:space:]]*=[[:space:]]*$OVERLAY_NAME([[:space:]]|,|\$)" "$CONFIG_TXT" 2>/dev/null; then
        echo "$CONFIG_TXT already enables $OVERLAY_NAME; no change."
    else
        echo "appending 'dtoverlay=$OVERLAY_NAME' to $CONFIG_TXT"
        run "$SUDO sh -c 'echo \"\" >> \"$CONFIG_TXT\"; echo \"# Added by rp1-overclock-tool $(date -Iseconds)\" >> \"$CONFIG_TXT\"; echo \"dtoverlay=$OVERLAY_NAME\" >> \"$CONFIG_TXT\"'"
    fi
    echo "reboot to apply."
else
    echo
    echo "Overlay installed but not loaded. To enable on next boot, add this"
    echo "line to $CONFIG_TXT:"
    echo
    echo "    dtoverlay=$OVERLAY_NAME"
    echo
    echo "Or re-run with --apply-config. Then reboot."
fi
