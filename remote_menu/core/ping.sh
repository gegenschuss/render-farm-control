#!/bin/bash
#  _____                         _
# |   __|___ ___ ___ ___ ___ ___| |_ _ _ ___ ___
# |  |  | -_| . | -_|   |_ -|  _|   | | |_ -|_ -|
# |_____|___|_  |___|_|_|___|___|_|_|___|___|___|
#           |___|
#
# Ping all farm nodes in parallel and print an UP/DOWN summary.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/ui.sh"
ui_require_secrets "$SCRIPT_DIR"

NODES=("${PING_NODES[@]}")

check_node_bg() {
  local name="$1" ip="$2" out_file="$3"
  if ui_ping "$ip"; then
    printf '%s|%s|OK\n' "$name" "$ip" > "$out_file"
  else
    printf '%s|%s|DOWN\n' "$name" "$ip" > "$out_file"
  fi
}

log_status() {
  local name="$1" ip="$2" status="$3" color="$4"
  printf '  [%s] %b%-8s%b %-10s %s\n' "$(ts)" "$color" "$status" "$C_RESET" "$name" "$ip"
}

spinner_until_done() {
  local pids=("$@")
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
      printf '\r  [%s] %bINFO%b Checking nodes in parallel... %s%s%s' \
        "$(ts)" "$C_ACCENT" "$C_RESET" \
        "$SPIN_COLOR" "${SPIN_FRAMES[$(( idx % ${#SPIN_FRAMES[@]} ))]}" "$SPIN_RESET"
      idx=$(( idx + 1 ))
      sleep 0.08
    fi
  done

  printf '\r%*s\r' "$WIDTH" ''
}

ui_play_logo
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

echo
ui_summary "${up_count} up ${UI_G_SEP} ${down_count} down"
