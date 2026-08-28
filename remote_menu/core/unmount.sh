#!/bin/bash
#  _____                         _
# |   __|___ ___ ___ ___ ___ ___| |_ _ _ ___ ___
# |  |  | -_| . | -_|   |_ -|  _|   | | |_ -|_ -|
# |_____|___|_  |___|_|_|___|___|_|_|___|___|___|
#           |___|
#
# Close Deadline Monitor and unmount all farm SMB shares.
# macOS unmounts via diskutil, Linux via gio/gvfs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/ui.sh"
ui_require_secrets "$SCRIPT_DIR"

SHARES=("${SMB_SHARES[@]}")

close_deadline_monitor() {
  local closed=0

  # macOS: try a graceful app quit first (if launched as an app process).
  if [ "$UI_OS" = "mac" ] && \
     osascript -e 'tell application "System Events" to (name of processes) contains "Deadline Monitor"' >/dev/null 2>&1; then
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

ui_play_logo
header "UNMOUNT REMOTE SHARES"

failed=0

section "CLOSE DEADLINE MONITOR"
close_deadline_monitor || failed=1

section "UNMOUNT SMB SHARES"
for share in "${SHARES[@]}"; do
  unmount_share "$share" || failed=1
done

echo
if [ "$failed" -eq 0 ]; then
  ui_summary "all shares handled"
else
  fail "One or more shares failed to unmount"
fi
ui_wait_exit
