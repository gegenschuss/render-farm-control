#!/bin/bash
#  _____                         _
# |   __|___ ___ ___ ___ ___ ___| |_ _ _ ___ ___
# |  |  | -_| . | -_|   |_ -|  _|   | | |_ -|_ -|
# |_____|___|_  |___|_|_|___|___|_|_|___|___|___|
#           |___|
#
# Mount the farm SMB shares — Tailscale IPs by default, LAN IPs with
# --local. macOS mounts via osascript/Finder, Linux via gio/gvfs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/ui.sh"
ui_require_secrets "$SCRIPT_DIR"

MOUNT_WAIT_SECONDS=5

MODE="tailscale"
if [[ "${1:-}" == "--local" || "${1:-}" == "-l" ]]; then
  MODE="local"
fi

if [[ "$MODE" == "local" ]]; then
  DEADLINE_HOST="${DEADLINE_HOST_LOCAL:-$DEADLINE_HOST}"
  NAS_HOST="${NAS_HOST_LOCAL:-$NAS_HOST}"
  WORKSTATION_HOST="${WORKSTATION_HOST_LOCAL:-$WORKSTATION_HOST}"
fi

ui_play_logo
if [[ "$MODE" == "local" ]]; then
  header "MOUNT SHARES (LOCAL LAN)"
else
  header "MOUNT SHARES (TAILSCALE)"
fi

section "MOUNT SMB SHARES"
mount_share "$DEADLINE_USER" "$DEADLINE_HOST" "$DEADLINE_SHARE"
mount_share "$NAS_USER" "$NAS_HOST" "$NAS_STUDIO_SHARE"
mount_share "$NAS_USER" "$NAS_HOST" "$NAS_BUERO_SHARE"

section "WORKSTATION SHARES"
spin_start "checking reachability: $WORKSTATION_HOST"
if ui_ping "$WORKSTATION_HOST"; then
  spin_stop
  pass "Host reachable: $WORKSTATION_HOST"
  mount_share "$WORKSTATION_USER" "$WORKSTATION_HOST" "$WORKSTATION_HOUDINI_SHARE"
  mount_share "$WORKSTATION_USER" "$WORKSTATION_HOST" "$WORKSTATION_NUKE_SHARE"
else
  spin_stop
  warn "Host not reachable: $WORKSTATION_HOST"
  warn "Skipping mounts: $WORKSTATION_HOUDINI_SHARE, $WORKSTATION_NUKE_SHARE"
fi
