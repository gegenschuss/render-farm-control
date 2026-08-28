#!/bin/bash
#  _____                         _
# |   __|___ ___ ___ ___ ___ ___| |_ _ _ ___ ___
# |  |  | -_| . | -_|   |_ -|  _|   | | |_ -|_ -|
# |_____|___|_  |___|_|_|___|___|_|_|___|___|___|
#           |___|
#
# Wake the farm: check Tailscale, trigger Wake-on-LAN via the relay,
# mount the SMB shares, then connect to the workstation farm menu.
# Runs on macOS and Linux.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/ui.sh"
ui_require_secrets "$SCRIPT_DIR"

MOUNT_WAIT_SECONDS=5
SSH_RETRY_SECONDS=10

ui_play_logo
header "REMOTE WAKE START"
echo

# 0. Preflight: check Tailscale is connected
log "INFO" "Checking Tailscale status"
TAILSCALE="$(tailscale_bin)"
if [ -z "$TAILSCALE" ]; then
  fail "Tailscale CLI not found. Install Tailscale and try again."
  exit 1
fi
STATUS=$("$TAILSCALE" status 2>/dev/null)
if [ $? -ne 0 ]; then
  fail "Tailscale is not running. Start it and try again."
  exit 1
fi
if echo "$STATUS" | grep -Eq "stopped|Logged out|NeedsLogin"; then
  fail "Tailscale is not connected. Run: tailscale up"
  exit 1
fi
pass "Tailscale connected"

# 1. Wake all nodes
section "WAKE NODES"
log "INFO" "Running remote wake script on $WAKE_RELAY_HOST"
if ssh "$WAKE_RELAY_HOST" "sleep 2 && export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH && $WAKE_RELAY_SCRIPT"; then
  pass "Wake command completed on $WAKE_RELAY_HOST"
else
  warn "Wake command reported issues on $WAKE_RELAY_HOST"
fi

# 2. Mount required SMB shares (credentials from Keychain / keyring)
section "MOUNT SMB SHARES"
mount_share "$DEADLINE_USER" "$DEADLINE_HOST" "$DEADLINE_SHARE"
mount_share "$NAS_USER" "$NAS_HOST" "$NAS_STUDIO_SHARE"
mount_share "$NAS_USER" "$NAS_HOST" "$NAS_BUERO_SHARE"

# 3. Retry SSH into the workstation until it has booted
section "CONNECT TO WORKSTATION"
attempt=0
spin_start "waiting for $WORKSTATION_SSH_HOST to boot"
until ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
    "$WORKSTATION_SSH_HOST" exit 2>/dev/null; do
  attempt=$((attempt + 1))
  sleep "$SSH_RETRY_SECONDS"
done
spin_stop
if [ "$attempt" -gt 0 ]; then
  pass "$WORKSTATION_SSH_HOST is reachable (after $attempt retries)"
else
  pass "$WORKSTATION_SSH_HOST is reachable"
fi
echo

# 4. Mount the workstation shares, then attach to the farm menu
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
ssh -t "$WORKSTATION_SSH_HOST" "$FARM_SCRIPT_PATH; bash -l"
