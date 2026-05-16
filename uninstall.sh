#!/usr/bin/env bash
# uninstall.sh — remove the installed RP1 overclock dtoverlay and optionally
# scrub the corresponding line from /boot/firmware/config.txt.

set -euo pipefail

OVERLAY_NAME="rp1-clk-333mhz"
BOOT_OVERLAYS_DIR="/boot/firmware/overlays"
CONFIG_TXT="/boot/firmware/config.txt"

SCRUB_CONFIG=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply-config) SCRUB_CONFIG=1; shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        -h|--help)
            echo "usage: $0 [--apply-config] [--dry-run]"
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

run() {
    if [[ $DRY_RUN -eq 1 ]]; then echo "  [dry-run] $*"; else eval "$@"; fi
}

if [[ $EUID -ne 0 ]]; then SUDO="sudo"; else SUDO=""; fi

target="$BOOT_OVERLAYS_DIR/$OVERLAY_NAME.dtbo"
if [[ -f "$target" ]]; then
    echo "removing $target"
    run "$SUDO rm -f \"$target\""
else
    echo "no overlay to remove at $target"
fi

if [[ $SCRUB_CONFIG -eq 1 ]]; then
    if [[ -f "$CONFIG_TXT" ]] && grep -qE "^[[:space:]]*dtoverlay[[:space:]]*=[[:space:]]*$OVERLAY_NAME" "$CONFIG_TXT"; then
        echo "removing dtoverlay=$OVERLAY_NAME line from $CONFIG_TXT"
        run "$SUDO sed -i.bak \"/^[[:space:]]*dtoverlay[[:space:]]*=[[:space:]]*$OVERLAY_NAME/d\" \"$CONFIG_TXT\""
    else
        echo "no dtoverlay=$OVERLAY_NAME line in $CONFIG_TXT"
    fi
    echo "reboot to revert."
else
    echo
    echo "Overlay file removed. If $CONFIG_TXT still has 'dtoverlay=$OVERLAY_NAME',"
    echo "the line will be ignored on next boot (file missing). To clean it up too:"
    echo "    $0 --apply-config"
fi
