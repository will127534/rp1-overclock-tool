#!/usr/bin/env bash
# install.sh — compile and install an RP1 overclock dtoverlay for the
# running kernel.
#
# generate_dtbo.py reads the running kernel's <dt-bindings/clock/rp1.h> +
# the live /sys/firmware/devicetree/base/.../rp1/clocks@18000/{
# assigned-clocks, assigned-clock-rates} arrays, locates the slots that
# hold RP1_PLL_SYS and RP1_CLK_SYS, and writes a .dts that re-specifies
# every slot exactly as the kernel currently has it — moving only those
# two entries to the target rate. Compiles with dtc. The resulting .dtbo
# lands in /boot/firmware/overlays/ and can be enabled by adding
# `dtoverlay=rp1-clk-333mhz` to /boot/firmware/config.txt.
#
# Requires:
#   - the linux-headers-<rel>+rpt-common-rpi package (for rp1.h)
#   - device-tree-compiler (for dtc)
#
# Usage:
#   ./install.sh                 install for the running kernel at the
#                               default 333 MHz target
#   ./install.sh --target 250000000
#                               different PLL grid point (must be
#                               pll_sys_core/N for integer N)
#   ./install.sh --apply-config  also append `dtoverlay=rp1-clk-333mhz`
#                               to /boot/firmware/config.txt
#   ./install.sh --kernel 6.12.75+rpt-rpi-2712
#                               look up headers for a specific kernel
#                               release (default: `uname -r`)
#   ./install.sh --dry-run       show the generated .dts and exit

set -euo pipefail

OVERLAY_NAME="rp1-clk-333mhz"
BOOT_OVERLAYS_DIR="/boot/firmware/overlays"
CONFIG_TXT="/boot/firmware/config.txt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN_SCRIPT="$SCRIPT_DIR/generate_dtbo.py"
DEFAULT_TARGET_HZ=333333333

DRY_RUN=0
APPLY_CONFIG=0
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
        --kernel)          KVER="$2"; shift 2 ;;
        --target)          TARGET_HZ="$2"; shift 2 ;;
        *)                 echo "unknown arg: $1" >&2; usage 1 ;;
    esac
done

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  [dry-run] $*"
    else
        # Callers pass a single pre-quoted command string (so that an empty
        # $SUDO expands away cleanly); re-parse via the shell.
        eval "$*"
    fi
}

if [[ $EUID -ne 0 ]]; then SUDO="sudo"; else SUDO=""; fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
dtbo="$tmpdir/$OVERLAY_NAME.dtbo"

echo "generating overlay for kernel $KVER (target ${TARGET_HZ} Hz)"
if [[ ! -x "$GEN_SCRIPT" ]]; then
    chmod +x "$GEN_SCRIPT" 2>/dev/null || true
fi

if [[ $DRY_RUN -eq 1 ]]; then
    "$GEN_SCRIPT" --kernel "$KVER" --target "$TARGET_HZ" \
                  --out "$dtbo" --dry-run
    exit 0
fi

"$GEN_SCRIPT" --kernel "$KVER" --target "$TARGET_HZ" \
              --out "$dtbo" --keep-dts

target="$BOOT_OVERLAYS_DIR/$OVERLAY_NAME.dtbo"
echo "installing -> $target"
run "$SUDO install -m 0644 \"$dtbo\" \"$target\""

# Stash the generated .dts next to the .dtbo so a future user can `cat` it
# to see exactly what the kernel was asked to do.
if [[ -f "${dtbo%.dtbo}.dts" ]]; then
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
