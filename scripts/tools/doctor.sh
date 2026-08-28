#!/bin/bash
#  _____                         _
# |   __|___ ___ ___ ___ ___ ___| |_ _ _ ___ ___
# |  |  | -_| . | -_|   |_ -|  _|   | | |_ -|_ -|
# |_____|___|_  |___|_|_|___|___|_|_|___|___|___|
#           |___|
#
cd "$(dirname "$0")"
source ../lib/config.sh

show_help() {
    cat << 'EOF'
Usage: ./doctor.sh [options]

Run dependency and connectivity checks for farm scripts.

Options:
  -h, --help    Show this help message

Examples:
  ./doctor.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_help
    exit 0
fi

"$FARM_SCRIPTS_DIR/lib/header.sh"
farm_print_title "FARM DOCTOR"

TOTAL=0
FAIL=0
WARN=0

check_cmd() {
    local cmd="$1"
    local required="$2"
    local label="$3"
    ((TOTAL++))
    if command -v "$cmd" >/dev/null 2>&1; then
        printf "  [OK]   %-20s %s\n" "$label" "$(command -v "$cmd")"
    else
        if [[ "$required" == "required" ]]; then
            printf "  [FAIL] %-20s missing\n" "$label"
            ((FAIL++))
        else
            printf "  [WARN] %-20s missing\n" "$label"
            ((WARN++))
        fi
    fi
}

farm_print_section "Platform"
echo "  Host OS: $FARM_OS"
echo ""

farm_print_section "Core tools"
check_cmd "bash" "required" "bash"
check_cmd "tmux" "required" "tmux"
check_cmd "ssh" "required" "ssh"
check_cmd "ping" "required" "ping"
check_cmd "base64" "required" "base64"

farm_print_section "Farm tools"
check_cmd "wakeonlan" "warn" "wakeonlan"
check_cmd "nvidia-smi" "warn" "nvidia-smi"

farm_print_section "Terminal integration"
if [[ "$FARM_OS" == "mac" ]]; then
    check_cmd "osascript" "required" "osascript"
    ((TOTAL++))
    if osascript -e 'id of application "iTerm2"' >/dev/null 2>&1; then
        printf "  [OK]   %-20s installed\n" "iTerm2"
    else
        printf "  [WARN] %-20s missing (Terminal.app used)\n" "iTerm2"
        ((WARN++))
    fi
else
    check_cmd "gnome-terminal" "warn" "gnome-terminal"
    check_cmd "xdotool" "warn" "xdotool"
    check_cmd "wmctrl" "warn" "wmctrl"
fi

farm_print_section "Deadline integration"
((TOTAL++))
if [ -x "$FARM_DEADLINECOMMAND" ]; then
    echo "  [OK]   deadlinecommand      $FARM_DEADLINECOMMAND"
else
    echo "  [WARN] deadlinecommand      not found at $FARM_DEADLINECOMMAND"
    ((WARN++))
fi

farm_print_section "Node reachability"
# Probe over ssh (the channel every tool uses): bare-name ping can
# resolve through a different transport and fake node status.
ONLINE=0
for node in "${NODES[@]}"; do
    ((TOTAL++))
    farm_spin_start "checking $node (ssh)"
    farm_get_node_os_status "$node" "ssh"
    _rc=$?
    farm_spin_stop
    case "$_rc" in
        2)
            echo "  [OK]   $node reachable (linux)"
            ((ONLINE++))
            ;;
        1)
            echo "  [OK]   $node reachable (windows)"
            ((ONLINE++))
            ;;
        *)
            echo "  [WARN] $node unreachable"
            ((WARN++))
            ;;
    esac
done

echo ""
farm_print_summary "$TOTAL checks ${FARM_G_SEP} $FAIL failures ${FARM_G_SEP} $WARN warnings ${FARM_G_SEP} nodes $ONLINE/${#NODES[@]}"
echo ""

if [ "$FAIL" -gt 0 ]; then
    farm_print_error "Farm doctor found blocking issues."
    exit 1
fi

farm_print_ok "Farm doctor complete."
exit 0
