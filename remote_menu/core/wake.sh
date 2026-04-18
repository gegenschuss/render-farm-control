#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
export LC_ALL=en_US.UTF-8

WIDTH=60
TAILSCALE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
MOUNT_WAIT_SECONDS=5
PING_COUNT=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load secrets (IPs, usernames, share names).
if [ ! -f "$SCRIPT_DIR/../config/secrets.sh" ]; then
    echo "ERROR: config/secrets.sh not found" >&2
    echo "Copy config/secrets.example.sh to config/secrets.sh and fill in your values." >&2
    exit 1
fi
source "$SCRIPT_DIR/../config/secrets.sh"
source "$SCRIPT_DIR/../lib/logo.sh"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_INFO=$'\033[36m'
  C_SUB=$'\033[35m'
  C_OK=$'\033[32m'
  C_WARN=$'\033[33m'
  C_FAIL=$'\033[31m'
else
  C_RESET=""
  C_BOLD=""
  C_INFO=""
  C_SUB=""
  C_OK=""
  C_WARN=""
  C_FAIL=""
fi

line_equals() {
  printf '%*s\n' "$WIDTH" '' | tr ' ' '='
}

center() {
  local msg="$1"
  printf '%*s\n' $(( (${#msg} + WIDTH) / 2 )) "$msg"
}

ts() {
  date '+%H:%M:%S'
}

log() {
  local level="$1"
  shift
  local msg="$*"
  local color=""
  case "$level" in
    INFO) color="$C_INFO" ;;
    OK)   color="$C_OK" ;;
    WARN) color="$C_WARN" ;;
    FAIL) color="$C_FAIL" ;;
  esac
  printf '[%s] %b%-5s%b %s\n' "$(ts)" "$color" "$level" "$C_RESET" "$msg"
}

subline() {
  printf '%*s\n' "$WIDTH" '' | tr ' ' '-'
}

section() {
  echo
  subline
  printf '%b    %s%b\n' "${C_SUB}${C_BOLD}" "$1" "$C_RESET"
  subline
  echo
}

header() {
  echo
  line_equals
  printf '%b    %s%b\n' "${C_INFO}${C_BOLD}" "$1" "$C_RESET"
  line_equals
  echo
}

pass() {
  log "OK" "$1"
}

warn() {
  log "WARN" "$1"
}

fail() {
  log "FAIL" "$1"
}

is_host_reachable() {
  local host="$1"
  if ping -c "$PING_COUNT" "$host" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

mount_share() {
  local user="$1"
  local host="$2"
  local share="$3"
  local mount_point="/Volumes/$share"
  local url="smb://$user@$host/$share"

  if mount | grep -q "$mount_point"; then
    pass "Already mounted: $mount_point"
    log "INFO" "Skipping mount wait; volume already ready"
    return 0
  fi

  log "INFO" "Mounting: $mount_point"
  if osascript -e "mount volume \"$url\"" >/dev/null 2>&1; then
    log "INFO" "Waiting $MOUNT_WAIT_SECONDS seconds for mount readiness"
    sleep "$MOUNT_WAIT_SECONDS"
    if mount | grep -q "$mount_point"; then
      pass "Mounted: $mount_point"
    else
      warn "Mount command completed but $mount_point not detected"
    fi
  else
    warn "Direct mount failed for $share; trying Finder fallback"
    if open -g "$url"; then
      log "INFO" "Waiting $MOUNT_WAIT_SECONDS seconds for mount readiness"
      sleep "$MOUNT_WAIT_SECONDS"
      if mount | grep -q "$mount_point"; then
        pass "Mounted via fallback: $mount_point"
      else
        warn "Fallback completed but $mount_point not detected"
      fi
    else
      warn "Failed to request mount for $share"
      warn "Check Keychain credential for $user@$host"
      return 1
    fi
  fi
}

play_logo_animation
header "REMOTE WAKE START"

# 0. Preflight: check Tailscale is connected
log "INFO" "Checking Tailscale status"
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

# 2. Mount required SMB shares (passwords handled by Keychain)
section "MOUNT SMB SHARES"
mount_share "$DEADLINE_USER" "$DEADLINE_HOST" "$DEADLINE_SHARE"
mount_share "$NAS_USER" "$NAS_HOST" "$NAS_STUDIO_SHARE"
mount_share "$NAS_USER" "$NAS_HOST" "$NAS_BUERO_SHARE"


# 4. Retry SSH into workstation every 10 seconds until successful
section "CONNECT TO WORKSTATION"
log "Waiting 50s for workstation to boot"
sleep 50
attempt=1
until ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no "$WORKSTATION_SSH_HOST" exit 2>/dev/null; do
  warn "Attempt $attempt failed; retrying in 10 seconds"
  attempt=$((attempt + 1))
  sleep 10
done
pass "$WORKSTATION_SSH_HOST is reachable"
subline
log "INFO" "Checking reachability: $WORKSTATION_HOST"
if is_host_reachable "$WORKSTATION_HOST"; then
  pass "Host reachable: $WORKSTATION_HOST"
  mount_share "$WORKSTATION_USER" "$WORKSTATION_HOST" "$WORKSTATION_HOUDINI_SHARE"
  mount_share "$WORKSTATION_USER" "$WORKSTATION_HOST" "$WORKSTATION_NUKE_SHARE"
else
  warn "Host not reachable: $WORKSTATION_HOST"
  warn "Skipping mounts: $WORKSTATION_HOUDINI_SHARE, $WORKSTATION_NUKE_SHARE"
fi
ssh -t "$WORKSTATION_SSH_HOST" "$FARM_SCRIPT_PATH; bash -l"