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

# Load secrets (workstation SSH host, farm script paths).
if [ ! -f "$SCRIPT_DIR/../config/secrets.sh" ]; then
    echo "ERROR: config/secrets.sh not found" >&2
    echo "Copy config/secrets.example.sh to config/secrets.sh and fill in your values." >&2
    exit 1
fi
source "$SCRIPT_DIR/../config/secrets.sh"
if [ -f "$SCRIPT_DIR/../lib/logo.sh" ]; then
  source "$SCRIPT_DIR/../lib/logo.sh"
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

line_equals() {
  printf '%*s\n' "$WIDTH" '' | tr ' ' '='
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

if declare -F play_logo_animation >/dev/null 2>&1; then
  play_logo_animation
fi

header "REMOTE SHUTDOWN"

section "SHUTDOWN FARM"
log "INFO" "Connecting to $WORKSTATION_SSH_HOST and sending shutdown commands..."
echo ""

ssh -A "$WORKSTATION_SSH_HOST" "$FARM_SHUTDOWN_SCRIPT_PATH --local --yes --postjob"
SSH_EXIT=$?

echo ""
subline
if [ "$SSH_EXIT" -eq 0 ]; then
  log "OK" "Shutdown commands sent. $WORKSTATION_SSH_HOST will power off in ~20 seconds."
else
  log "FAIL" "SSH exited with code $SSH_EXIT — check $WORKSTATION_SSH_HOST connectivity"
fi
subline

read -r -p "Press Enter to exit..."
