#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
export LC_ALL=en_US.UTF-8

WIDTH=60

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load secrets (share names).
if [ ! -f "$SCRIPT_DIR/../config/secrets.sh" ]; then
    echo "ERROR: config/secrets.sh not found" >&2
    echo "Copy config/secrets.example.sh to config/secrets.sh and fill in your values." >&2
    exit 1
fi
source "$SCRIPT_DIR/../config/secrets.sh"
source "$SCRIPT_DIR/../lib/logo.sh"

SHARES=("${SMB_SHARES[@]}")

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

close_deadline_monitor() {
  local closed=0

  # Try graceful app quit first (if launched as an app process).
  if osascript -e 'tell application "System Events" to (name of processes) contains "Deadline Monitor"' >/dev/null 2>&1; then
    log "INFO" "Closing Deadline Monitor"
    osascript -e 'tell application "Deadline Monitor" to quit' >/dev/null 2>&1
    sleep 1
    closed=1
  fi

  # If the binary is still running, terminate it directly.
  if pgrep -x "deadlinemonitor" >/dev/null 2>&1; then
    log "INFO" "Stopping deadlinemonitor process"
    pkill -x "deadlinemonitor" >/dev/null 2>&1
    sleep 1
    closed=1
  fi

  if pgrep -x "deadlinemonitor" >/dev/null 2>&1; then
    warn "Deadline Monitor still running"
    return 1
  fi

  if [ "$closed" -eq 1 ]; then
    pass "Deadline Monitor closed"
  else
    pass "Deadline Monitor not running"
  fi
  return 0
}

unmount_share() {
  local share="$1"
  local mount_point="/Volumes/$share"

  if ! mount | grep -q "$mount_point"; then
    pass "Already unmounted: $mount_point"
    return 0
  fi

  log "INFO" "Unmounting: $mount_point"

  if diskutil unmount "$mount_point" >/dev/null 2>&1; then
    pass "Unmounted: $mount_point"
    return 0
  fi

  warn "Normal unmount failed, trying force unmount"
  if diskutil unmount force "$mount_point" >/dev/null 2>&1; then
    pass "Force unmounted: $mount_point"
    return 0
  fi

  fail "Could not unmount: $mount_point"
  return 1
}

play_logo_animation
header "UNMOUNT REMOTE SHARES"

failed=0

section "CLOSE DEADLINE MONITOR"
close_deadline_monitor || failed=1

section "UNMOUNT SMB SHARES"
for share in "${SHARES[@]}"; do
  unmount_share "$share" || failed=1
done

subline
if [ "$failed" -eq 0 ]; then
  pass "All shares handled successfully"
else
  fail "One or more shares failed to unmount"
fi
subline
read -r -p "Press Enter to exit..."
