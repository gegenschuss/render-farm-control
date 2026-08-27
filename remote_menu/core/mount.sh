#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
export LC_ALL=en_US.UTF-8

WIDTH=60
MOUNT_WAIT_SECONDS=5
PING_COUNT=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$SCRIPT_DIR/../config/secrets.sh" ]; then
    echo "ERROR: config/secrets.sh not found" >&2
    echo "Copy config/secrets.example.sh to config/secrets.sh and fill in your values." >&2
    exit 1
fi
source "$SCRIPT_DIR/../config/secrets.sh"
source "$SCRIPT_DIR/../lib/logo.sh"
[ -f "$SCRIPT_DIR/../lib/spin.sh" ] && source "$SCRIPT_DIR/../lib/spin.sh"

MODE="tailscale"
if [[ "${1:-}" == "--local" || "${1:-}" == "-l" ]]; then
  MODE="local"
fi

if [[ "$MODE" == "local" ]]; then
  DEADLINE_HOST="${DEADLINE_HOST_LOCAL:-$DEADLINE_HOST}"
  NAS_HOST="${NAS_HOST_LOCAL:-$NAS_HOST}"
  WORKSTATION_HOST="${WORKSTATION_HOST_LOCAL:-$WORKSTATION_HOST}"
fi

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

line_equals() { printf '%*s\n' "$WIDTH" '' | tr ' ' '='; }
subline()     { printf '%*s\n' "$WIDTH" '' | tr ' ' '-'; }
ts()          { date '+%H:%M:%S'; }

log() {
  local level="$1"; shift
  local msg="$*" color=""
  case "$level" in
    INFO) color="$C_INFO" ;;
    OK)   color="$C_OK" ;;
    WARN) color="$C_WARN" ;;
    FAIL) color="$C_FAIL" ;;
  esac
  printf '[%s] %b%-5s%b %s\n' "$(ts)" "$color" "$level" "$C_RESET" "$msg"
}

pass() { log "OK"   "$1"; }
warn() { log "WARN" "$1"; }
fail() { log "FAIL" "$1"; }

section() {
  echo; subline
  printf '%b    %s%b\n' "${C_SUB}${C_BOLD}" "$1" "$C_RESET"
  subline; echo
}

header() {
  echo; line_equals
  printf '%b    %s%b\n' "${C_INFO}${C_BOLD}" "$1" "$C_RESET"
  line_equals; echo
}

is_host_reachable() {
  ping -c "$PING_COUNT" "$1" >/dev/null 2>&1
}

mount_share() {
  local user="$1" host="$2" share="$3"
  local mount_point="/Volumes/$share"
  local url="smb://$user@$host/$share"

  if mount | grep -q "$mount_point"; then
    pass "Already mounted: $mount_point"
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
if is_host_reachable "$WORKSTATION_HOST"; then
  spin_stop
  pass "Host reachable: $WORKSTATION_HOST"
  mount_share "$WORKSTATION_USER" "$WORKSTATION_HOST" "$WORKSTATION_HOUDINI_SHARE"
  mount_share "$WORKSTATION_USER" "$WORKSTATION_HOST" "$WORKSTATION_NUKE_SHARE"
else
  spin_stop
  warn "Host not reachable: $WORKSTATION_HOST"
  warn "Skipping mounts: $WORKSTATION_HOUDINI_SHARE, $WORKSTATION_NUKE_SHARE"
fi
