#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
cd "$(dirname "$0")"
set -eE
source ../lib/config.sh

trap 'echo ""; echo "farm_selftest: FAILED at line ${LINENO}: ${BASH_COMMAND}"' ERR

show_help() {
    cat << 'EOF'
Usage: ./selftest.sh [--quick]

Run a deep regression smoke test for farm scripts:
  - syntax check on all shell scripts
  - key command help routes
  - safe dry-run checks for update/reboot/shutdown
  - farm doctor dependency/connectivity checks
  - additional deep safety checks (default)

Options:
  --quick   Skip deep checks and run only steps [1/4]..[4/4]
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_help
    exit 0
fi

DEEP=1
if [[ "${1:-}" == "--quick" ]]; then
    DEEP=0
fi

if [[ -t 1 ]]; then
    clear
    "$FARM_SCRIPTS_DIR/lib/header.sh"
    echo ""
fi

farm_print_title "FARM SELFTEST"

echo "[1/4] Syntax checking all shell scripts..."
for f in "$FARM_SCRIPTS_DIR"/{lib,core,deadline,tools}/*.sh; do
    bash -n "$f" || exit 1
done

echo "[2/4] Checking merged entrypoints..."
if bash -c 'declare -A __farm_test_assoc' >/dev/null 2>&1; then
    "$FARM_SCRIPTS_DIR/core/node_session.sh" control --help >/dev/null || exit 1
    "$FARM_SCRIPTS_DIR/core/node_session.sh" nvtop --help >/dev/null || exit 1
    "$FARM_SCRIPTS_DIR/tools/install_app.sh" deadline --help >/dev/null || exit 1
    "$FARM_SCRIPTS_DIR/tools/install_app.sh" houdini --help >/dev/null || exit 1
    "$FARM_SCRIPTS_DIR/core/power_action.sh" shutdown --help >/dev/null || exit 1
    "$FARM_SCRIPTS_DIR/core/power_action.sh" reboot --help >/dev/null || exit 1
else
    echo "  Skipping merged entrypoint tests: bash lacks associative arrays."
fi

echo "[3/4] Running safe dry-runs..."
if bash -c 'declare -A __farm_test_assoc' >/dev/null 2>&1; then
    "$FARM_SCRIPTS_DIR/core/update.sh" --dry-run --no-local --yes >/dev/null
    "$FARM_SCRIPTS_DIR/core/shutdown.sh" --dry-run --no-local --yes --force >/dev/null
    "$FARM_SCRIPTS_DIR/core/reboot.sh" --dry-run --no-local --yes --force >/dev/null
else
    echo "  Skipping dry-runs: bash lacks associative arrays on this host."
fi

echo "[4/4] Checking launcher help..."
"$FARM_SCRIPTS_DIR/lib/help.sh" --help >/dev/null || exit 1

if [ "$DEEP" -eq 1 ]; then
    echo "[deep] Running additional safe checks..."
    if bash -c 'declare -A __farm_test_assoc' >/dev/null 2>&1; then
        "$FARM_SCRIPTS_DIR/core/wake.sh" --prejob --prejob-wait=3 --yes --dry-run >/dev/null || exit 1
        "$FARM_SCRIPTS_DIR/core/status.sh" --help >/dev/null || exit 1
    else
        echo "  Skipping deep runtime checks: bash lacks associative arrays."
    fi
fi

echo "[doctor] Running farm doctor checks..."
"$FARM_SCRIPTS_DIR/tools/doctor.sh" >/dev/null || exit 1

echo ""
echo "farm_selftest: OK"
