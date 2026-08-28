#!/bin/bash
#  _____                         _
# |   __|___ ___ ___ ___ ___ ___| |_ _ _ ___ ___
# |  |  | -_| . | -_|   |_ -|  _|   | | |_ -|_ -|
# |_____|___|_  |___|_|_|___|___|_|_|___|___|___|
#           |___|
#
cd "$(dirname "$0")"
source ./config.sh

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat << 'EOF'
Usage: ./help.sh

Show a one-page index of farm scripts and common flags.
EOF
    exit 0
fi

./header.sh
echo ""


W="${FARM_UI_WIDTH:-60}"

# Section header in the same style as the menus: dim rule, accent label.
sec() {
    local label fill line=""
    label=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    fill=$(( W - ${#label} - 7 ))
    (( fill < 0 )) && fill=0
    printf -v line "%${fill}s" ""
    printf "  ${FARM_C_DIM}${FARM_G_RULE}${FARM_G_RULE}${FARM_C_RESET} ${FARM_C_TITLE}%s${FARM_C_RESET} ${FARM_C_DIM}%s${FARM_C_RESET}\n" \
        "$label" "${line// /$FARM_G_RULE}"
}
cmd() { printf "   ${FARM_C_SECTION}%-22s${FARM_C_RESET} %s\n" "$1" "$2"; }
sub() { printf "     ${FARM_C_DIM}%-9s %s${FARM_C_RESET}\n" "$1" "$2"; }
dlabel() { printf "   ${FARM_C_SECTION}%s${FARM_C_RESET}\n" "$1"; }
dcmd() { printf "     %s\n" "$1"; }
dnote() { printf "     ${FARM_C_DIM}%s${FARM_C_RESET}\n" "$1"; }
tip() { printf "   ${FARM_C_SECTION}${FARM_G_SEP}${FARM_C_RESET} %s\n" "$1"; }

farm_print_title "Farm Help v${FARM_VERSION}"

sec "CORE"
cmd "farm.sh" "Interactive launcher"

echo ""
sec "OPERATIONS"
cmd "wake.sh" "Wake/start nodes"
sub "flags:" "--silent --silent-strict --prejob-wait=SEC"
sub "" "--yes --dry-run"
cmd "status.sh" "Full node report"
cmd "node_session.sh" "control | nvtop"
sub "flags:" "--yes --local --no-local"
cmd "update.sh" "Package update (Linux)"
sub "flags:" "--yes --dry-run --local"
sub "" "--no-local"
cmd "reboot.sh" "Reboot flow"
sub "flags:" "--yes --dry-run --local"
sub "" "--no-local --windows-only"
cmd "shutdown.sh" "Shutdown flow"
sub "flags:" "--yes --dry-run --delay=MIN"
sub "" "--local --no-local"
cmd "submit.sh" "Submit CommandScript job"
sub "example:" "--allow-list node-01-gpu1,..."
cmd "submit_shutdown.sh" "Submit suspended post-job shutdown"
cmd "power_action.sh" "Shared power engine"
sub "usage:" "shutdown|reboot [flags]"

echo ""
sec "INSTALLERS"
cmd "install_app.sh" "houdini | deadline"
cmd "import_mocha.sh" "Mocha Pro rpm import (local)"
cmd "update_blender.sh" "Blender update (local)"
cmd "update_resolve.sh" "DaVinci Resolve update (local)"
cmd "update_nuke.sh" "Nuke install to /opt (local)"
cmd "license_houdini.sh" "Update Houdini license (sesictrl)"
sub "flags:" "--yes --dry-run --local --no-local"

echo ""
sec "UTILITIES"
cmd "selftest.sh" "Deep check + doctor (--quick for fast)"

echo ""
sec "QUICK TIPS"
tip "Use --help on any script."
tip "Use --dry-run before reboot/shutdown/update/wake."

echo ""
sec "WAKE / SHUTDOWN AUTOMATION"
dnote "(paths relative to the repo root)"
dlabel "Pre-job wake:"
dcmd "scripts/core/wake.sh --silent --prejob-wait=45"
dnote "# Log:  /tmp/farm_wake_silent.log"
dnote "# Live: tail -f /tmp/farm_wake_silent.log"
dlabel "Pre-job wake strict:"
dcmd "scripts/core/wake.sh --silent-strict --prejob-wait=60"
dlabel "Override log path:"
dcmd "FARM_PREJOB_LOG_FILE=/tmp/custom.log \\"
dcmd "  scripts/core/wake.sh --silent"
dlabel "Python Pre Job Script:"
dcmd "deadline/prejob_wake.py"
dnote "# Uses wake.sh --silent by default"
dnote "# Env: FARM_WAKE_PREJOB_WAIT=45 FARM_WAKE_PREJOB_STRICT=1"
dlabel "AutoWake systemd timer (user-level):"
sub "toggle:" "Gegenschuss_farm_control.sh (option 9)"
dlabel "Enable (manual):"
dcmd "  scripts/deadline/autowake.sh install"
dcmd "  scripts/deadline/autowake.sh enable"
dcmd "  scripts/deadline/autowake.sh run-now"
dlabel "Disable (manual):"
dcmd "  scripts/deadline/autowake.sh disable"
dcmd "  scripts/deadline/autowake.sh uninstall"
dlabel "Unit file locations:"
dcmd "  ~/.config/systemd/user/farm-autowake.service"
dcmd "  ~/.config/systemd/user/farm-autowake.timer"
sub "status:" "systemctl --user status farm-autowake.timer"
dlabel "Batch finalizer:"
dcmd "scripts/deadline/finalize.sh --grace-seconds=30"
dcmd "scripts/deadline/finalize.sh --no-shutdown"
dlabel "Submit command job:"
dcmd "scripts/deadline/submit.sh \\"
dcmd "  --script scripts/core/shutdown.sh -- --deadline-postjob"
dlabel "Post-job shutdown:"
dcmd "scripts/core/shutdown.sh --deadline-postjob"

echo ""
