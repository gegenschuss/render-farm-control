#!/bin/bash
#  _____                         _
# |   __|___ ___ ___ ___ ___ ___| |_ _ _ ___ ___
# |  |  | -_| . | -_|   |_ -|  _|   | | |_ -|_ -|
# |_____|___|_  |___|_|_|___|___|_|_|___|___|___|
#           |___|
#
# Shut down the remote farm: run the workstation shutdown script over
# SSH (it powers off the nodes and then itself).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/ui.sh"
ui_require_secrets "$SCRIPT_DIR"

ui_play_logo
header "REMOTE SHUTDOWN"

section "SHUTDOWN FARM"
log "INFO" "Connecting to $WORKSTATION_SSH_HOST and sending shutdown commands..."
echo ""

ssh -A "$WORKSTATION_SSH_HOST" "$FARM_SHUTDOWN_SCRIPT_PATH --local --yes --postjob"
SSH_EXIT=$?

echo ""
if [ "$SSH_EXIT" -eq 0 ]; then
  ui_summary "shutdown sent ${UI_G_SEP} $WORKSTATION_SSH_HOST powers off in ~20s"
else
  fail "SSH exited with code $SSH_EXIT — check $WORKSTATION_SSH_HOST connectivity"
fi

ui_wait_exit
