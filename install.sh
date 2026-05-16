#!/usr/bin/env bash
# install.sh — compile the right RP1 overclock dtoverlay for the running
# kernel and install it to /boot/firmware/overlays/.
#
# Why a separate tool: the .dtso files are kernel-specific (they hard-code
# the index of RP1_CLK_SYS in the rp1_clocks `assigned-clock-rates` array,
# which is determined by the kernel's clock binding). Shipping a single
# overlay alongside libcamera or any other userspace package would silently
# clock the wrong domain on a kernel that renumbers the binding. This tool
# keeps a directory of per-kernel-series overlays, picks the one that
# matches `uname -r`, and refuses to install if there's no match.
#
# Usage:
#   ./install.sh                  detect kernel, compile & install
#   ./install.sh --apply-config   also append `dtoverlay=rp1-300mhz` to
#                                 /boot/firmware/config.txt if absent
#   ./install.sh --kernel 6.12    force a specific kernel-series match
#                                 (use when cross-installing for a
#                                 different boot kernel)
#   ./install.sh --dry-run        show what would happen, change nothing

set -euo pipefail

OVERLAY_NAME="rp1-300mhz"
BOOT_OVERLAYS_DIR="/boot/firmware/overlays"
CONFIG_TXT="/boot/firmware/config.txt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAYS_SRC_DIR="$SCRIPT_DIR/overlays"

DRY_RUN=0
APPLY_CONFIG=0
KVER_OVERRIDE=""

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)        usage 0 ;;
        --dry-run)        DRY_RUN=1; shift ;;
        --apply-config)   APPLY_CONFIG=1; shift ;;
        --kernel)         KVER_OVERRIDE="$2"; shift 2 ;;
        *)                echo "unknown arg: $1" >&2; usage 1 ;;
    esac
done

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  [dry-run] $*"
    else
        eval "$@"
    fi
}

# 1. Detect kernel series (e.g. "6.12" from "6.12.75-rpt-rpi-2712").
if [[ -n "$KVER_OVERRIDE" ]]; then
    kver="$KVER_OVERRIDE"
else
    kver="$(uname -r)"
fi
kseries="$(echo "$kver" | awk -F. '{print $1"."$2}')"
echo "kernel series: $kseries (from $kver)"

# 2. Find a matching .dtso. We accept exact-series match. If a closer-prefix
# overlay file exists (e.g. kernel6.12-rpi) we'd add it later; for now the
# convention is `<NAME>-kernel<MAJ>.<MIN>.dtso`.
candidate="$OVERLAYS_SRC_DIR/$OVERLAY_NAME-kernel$kseries.dtso"
if [[ ! -f "$candidate" ]]; then
    echo "error: no overlay for kernel $kseries in $OVERLAYS_SRC_DIR" >&2
    echo "available:" >&2
    ls "$OVERLAYS_SRC_DIR"/*.dtso >&2 || true
    echo "build your own .dtso for this kernel series and add it to overlays/." >&2
    exit 2
fi
echo "using source: $candidate"

# 3. Make sure dtc is available.
if ! command -v dtc >/dev/null 2>&1; then
    echo "error: dtc (device-tree compiler) not found. Install with:" >&2
    echo "  sudo apt install device-tree-compiler" >&2
    exit 3
fi

# 4. Compile to a temporary .dtbo.
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
dtbo="$tmpdir/$OVERLAY_NAME.dtbo"
echo "compiling $(basename "$candidate") -> $(basename "$dtbo")"
run "dtc -@ -I dts -O dtb -o \"$dtbo\" \"$candidate\" 2>/dev/null"

# 5. Install (needs root for /boot/firmware/overlays).
target="$BOOT_OVERLAYS_DIR/$OVERLAY_NAME.dtbo"
echo "installing -> $target"
if [[ $EUID -ne 0 ]]; then
    SUDO="sudo"
else
    SUDO=""
fi
run "$SUDO install -m 0644 \"$dtbo\" \"$target\""

# 6. Optionally edit config.txt.
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
