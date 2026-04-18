#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
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

SCRIPT_DIR="$(pwd)"

W="${FARM_UI_WIDTH:-72}"
line() { printf "%-${W}s\n" "$1"; }
sec() { printf "${FARM_C_WARN}%-${W}s${FARM_C_RESET}\n" "$1"; }
cmd() { printf "  ${FARM_C_OK}%-32s${FARM_C_RESET} %s\n" "$1" "$2"; }
sub() { printf "    ${FARM_C_WARN}%-12s${FARM_C_RESET} ${FARM_C_SECTION}%s${FARM_C_RESET}\n" "$1" "$2"; }
dlabel() { printf "  ${FARM_C_TITLE}%s${FARM_C_RESET}\n" "$1"; }
dcmd() { printf "    ${FARM_C_OK}%s${FARM_C_RESET}\n" "$1"; }
dnote() { printf "    ${FARM_C_SECTION}%s${FARM_C_RESET}\n" "$1"; }
tip() { printf "  ${FARM_C_OK}- ${FARM_C_RESET}%s\n" "$1"; }

farm_print_rule "$W"
printf "${FARM_C_TITLE} Farm Help Index v${FARM_VERSION}${FARM_C_RESET}\n"
farm_print_rule "$W"
echo ""

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
cmd "update.sh" "Apt update (Linux)"
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

echo ""
sec "UTILITIES"
cmd "selftest.sh" "Deep check + doctor (--quick for fast)"

echo ""
sec "QUICK TIPS"
tip "Use --help on any script."
tip "Use --dry-run before reboot/shutdown/update/wake."

echo ""
sec "WAKE / SHUTDOWN AUTOMATION"
dlabel "Pre-job wake:"
dcmd "${SCRIPT_DIR}/wake.sh \\"
dcmd "  --silent --prejob-wait=45"
dnote "# Log:  /tmp/farm_wake_silent.log"
dnote "# Live: tail -f /tmp/farm_wake_silent.log"
dlabel "Pre-job wake strict:"
dcmd "${SCRIPT_DIR}/wake.sh \\"
dcmd "  --silent-strict --prejob-wait=60"
dlabel "Override log path:"
dcmd "FARM_PREJOB_LOG_FILE=/tmp/custom.log ${SCRIPT_DIR}/wake.sh --silent"
dlabel "Python Pre Job Script:"
dcmd "${SCRIPT_DIR}/deadline/prejob_wake.py"
dnote "# Uses wake.sh --silent by default"
dnote "# Optional env: FARM_WAKE_PREJOB_WAIT=45 FARM_WAKE_PREJOB_STRICT=1"
dlabel "AutoWake systemd timer (user-level):"
sub "toggle:" "${SCRIPT_DIR}/Gegenschuss_farm_control.sh (option 9)"
dlabel "Enable (manual):"
dcmd "  ${SCRIPT_DIR}/autowake.sh install"
dcmd "  ${SCRIPT_DIR}/autowake.sh enable"
dcmd "  ${SCRIPT_DIR}/autowake.sh run-now"
dlabel "Disable (manual):"
dcmd "  ${SCRIPT_DIR}/autowake.sh disable"
dcmd "  ${SCRIPT_DIR}/autowake.sh uninstall"
dlabel "Unit file locations:"
dcmd "  ${HOME}/.config/systemd/user/farm-autowake.service"
dcmd "  ${HOME}/.config/systemd/user/farm-autowake.timer"
sub "status:" "systemctl --user status farm-autowake.timer"
dlabel "Batch finalizer:"
dcmd "${SCRIPT_DIR}/finalize.sh \\"
dcmd "  --grace-seconds=30"
dcmd "${SCRIPT_DIR}/finalize.sh \\"
dcmd "  --no-shutdown"
dlabel "Submit command job:"
dcmd "${SCRIPT_DIR}/submit.sh \\"
dcmd "  --script ${SCRIPT_DIR}/shutdown.sh -- --deadline-postjob"
dlabel "Post-job shutdown:"
dcmd "${SCRIPT_DIR}/shutdown.sh --deadline-postjob"

echo ""
