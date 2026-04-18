#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
export LC_ALL=en_US.UTF-8

WIDTH=60
PING_COUNT=1
PING_TIMEOUT_MS=1000

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load secrets (IP addresses, node list).
if [ ! -f "$SCRIPT_DIR/../config/secrets.sh" ]; then
    echo "ERROR: config/secrets.sh not found" >&2
    echo "Copy config/secrets.example.sh to config/secrets.sh and fill in your values." >&2
    exit 1
fi
source "$SCRIPT_DIR/../config/secrets.sh"

NODES=("${PING_NODES[@]}")
if [ -f "$SCRIPT_DIR/../lib/logo.sh" ]; then
  source "$SCRIPT_DIR/../lib/logo.sh"
fi

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_HEAD=$'\033[36m'
  C_SUB=$'\033[35m'
  C_OK=$'\033[32m'
  C_FAIL=$'\033[31m'
else
  C_RESET=""
  C_BOLD=""
  C_HEAD=""
  C_SUB=""
  C_OK=""
  C_FAIL=""
fi

line_equals() {
  printf '%*s\n' "$WIDTH" '' | tr ' ' '='
}

subline() {
  printf '%*s\n' "$WIDTH" '' | tr ' ' '-'
}

header() {
  echo
  line_equals
  printf '%b    %s%b\n' "${C_HEAD}${C_BOLD}" "$1" "$C_RESET"
  line_equals
  echo
}

section() {
  echo
  subline
  printf '%b    %s%b\n' "${C_SUB}${C_BOLD}" "$1" "$C_RESET"
  subline
  echo
}

ts() {
  date '+%H:%M:%S'
}

check_node_bg() {
  local name="$1"
  local ip="$2"
  local out_file="$3"

  if ping -c "$PING_COUNT" -W "$PING_TIMEOUT_MS" "$ip" >/dev/null 2>&1; then
    printf '%s|%s|OK\n' "$name" "$ip" > "$out_file"
  else
    printf '%s|%s|DOWN\n' "$name" "$ip" > "$out_file"
  fi
}

log_status() {
  local name="$1"
  local ip="$2"
  local status="$3"
  local color="$4"
  printf '[%s] %b%-8s%b %-10s %s\n' "$(ts)" "$color" "$status" "$C_RESET" "$name" "$ip"
}

spinner_until_done() {
  local pids=("$@")
  local chars='|/-\'
  local idx=0
  local all_done=0

  while [ "$all_done" -eq 0 ]; do
    all_done=1
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" >/dev/null 2>&1; then
        all_done=0
        break
      fi
    done

    if [ "$all_done" -eq 0 ]; then
      printf '\r[%s] %bINFO%b Checking nodes in parallel... %c' "$(ts)" "$C_SUB" "$C_RESET" "${chars:$idx:1}"
      idx=$(( (idx + 1) % 4 ))
      sleep 0.12
    fi
  done

  printf '\r%*s\r' "$WIDTH" ''
}

if declare -F play_logo_animation >/dev/null 2>&1; then
  play_logo_animation
fi

header "REMOTE STATUS"
section "PING NODES"

up_count=0
down_count=0
tmp_dir="$(mktemp -d)"
declare -a pids

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

for node in "${NODES[@]}"; do
  IFS='|' read -r name ip <<< "$node"
  out_file="$tmp_dir/$name.result"
  check_node_bg "$name" "$ip" "$out_file" &
  pids+=("$!")
done

spinner_until_done "${pids[@]}"

for node in "${NODES[@]}"; do
  IFS='|' read -r name ip <<< "$node"
  out_file="$tmp_dir/$name.result"
  if [ ! -f "$out_file" ]; then
    log_status "$name" "$ip" "DOWN" "$C_FAIL"
    down_count=$((down_count + 1))
    continue
  fi

  IFS='|' read -r _ _ status < "$out_file"
  if [ "$status" = "OK" ]; then
    log_status "$name" "$ip" "OK" "$C_OK"
    up_count=$((up_count + 1))
  else
    log_status "$name" "$ip" "DOWN" "$C_FAIL"
    down_count=$((down_count + 1))
  fi
done

subline
printf '[%s] %bUP%b: %d  %bDOWN%b: %d\n' "$(ts)" "$C_OK" "$C_RESET" "$up_count" "$C_FAIL" "$C_RESET" "$down_count"
subline
