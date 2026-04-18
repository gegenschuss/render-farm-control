#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
cd "$(dirname "$0")"
source ../lib/config.sh
farm_require_bash4 "update.sh"

show_help() {
    cat << 'EOF'
Usage: ./update.sh [options]

Run apt update/full-upgrade on eligible Linux farm nodes.

Options:
  -h, --help      Show this help message
  -y, --yes       Auto-confirm prompts
      --dry-run   Print planned actions without executing updates
      --local     Include local workstation update
      --no-local  Exclude local workstation update

Examples:
  ./update.sh
  ./update.sh --yes --no-local
  ./update.sh --dry-run --local
EOF
}

AUTO_YES=0
DRY_RUN=0
FORCE_LOCAL=""
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            show_help
            exit 0
            ;;
        -y|--yes) AUTO_YES=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --local) FORCE_LOCAL="y" ;;
        --no-local) FORCE_LOCAL="n" ;;
        *) farm_die_unknown_option "$arg" show_help ;;
    esac
done

"$FARM_SCRIPTS_DIR/lib/header.sh"
echo ""
# --- CONFIGURATION ---
X_START="$FARM_X_START"
SESSION="farm_update"

farm_print_title "FARM UPDATE"

# --- REMOTE COMMAND (passwordless sudo) ---
REMOTE_CMD="sudo DEBIAN_FRONTEND=noninteractive \
apt update && \
sudo DEBIAN_FRONTEND=noninteractive \
apt full-upgrade -y && \
sudo needrestart -r a; \
if [ -f /var/run/reboot-required ]; then \
    echo -e '\e[31m[!!!] REBOOT REQUIRED [!!!]\e[0m'; \
else \
    echo -e '\e[32m[OK] No reboot necessary.\e[0m'; \
fi; \
echo '--- UPDATE DONE ---'; \
echo 'Press Enter to exit.'; \
read"

# --- LOCAL COMMAND (passwordless sudo via /etc/sudoers.d/farm) ---
LOCAL_CMD="$REMOTE_CMD"

if [ "$FORCE_LOCAL" = "y" ]; then
    UPDATE_LOCAL="y"
else
    UPDATE_LOCAL="n"
fi

# --- CHECK NODE STATUS ---
echo ""
farm_print_section "Checking node status"
echo ""
declare -A NODE_OS
for NODE in "${NODES[@]}"; do
    farm_get_node_os_status "$NODE" "ping"
    NODE_OS[$NODE]=$?
    case ${NODE_OS[$NODE]} in
        0)
            echo "$(farm_node_tag "$NODE") offline - skipped"
            ;;
        1)
            echo "$(farm_node_tag "$NODE") on Windows - skipped"
            print_windows_tasks "$NODE"
            ;;
        2)
            if farm_is_dual_boot_node "$NODE"; then
                echo "$(farm_node_tag "$NODE") on Linux - will update"
            else
                echo "$(farm_node_tag "$NODE") online - will update"
            fi
            ;;
    esac
done

if [[ "$UPDATE_LOCAL" =~ ^[Yy]$ ]]; then
    echo "$(farm_node_tag "$FARM_LOCAL_NAME") local workstation - will update"
else
    echo "$(farm_node_tag "$FARM_LOCAL_NAME") local workstation - skipped"
fi

echo ""
if [ "$AUTO_YES" -eq 1 ]; then
    echo "Auto-yes enabled: starting updates."
else
    if ! farm_press_any_or_q "Press any key to start, q to abort"; then
        echo "Aborted."
        exit 0
    fi
fi
echo ""

if [ "$DRY_RUN" -eq 1 ]; then
    farm_print_ok "Dry-run complete. No changes were made."
    echo ""
    exit 0
fi

# --- TMUX SETUP ---
farm_tmux_reset_session "$SESSION"

for NODE in "${NODES[@]}"; do
    OS=${NODE_OS[$NODE]}

    # Only open panes for nodes that will actually update (Linux)
    if [ "$OS" -ne 2 ]; then
        continue
    fi

    NODE_CMD="ssh -t -F ~/.ssh/config -o LogLevel=ERROR $NODE \"$REMOTE_CMD\""
    farm_tmux_add_pane "$SESSION" "$NODE_CMD" "NODE: $NODE"
done

# --- LOCAL WORKSTATION PANE ---
if [[ "$UPDATE_LOCAL" == "y" || "$UPDATE_LOCAL" == "Y" ]]; then
    farm_tmux_add_pane "$SESSION" "$LOCAL_CMD" "$FARM_LOCAL_NAME"
fi

# --- APPLY SHARED TMUX CONFIG ---
farm_tmux_apply_config "$SESSION"

# --- SELECT LOCAL PANE AS ACTIVE ---
if [[ "$UPDATE_LOCAL" == "y" || "$UPDATE_LOCAL" == "Y" ]]; then
    LOCAL_PANE=$(tmux list-panes -t $SESSION -F '#{pane_index}' | tail -1)
    tmux select-pane -t "$SESSION.$LOCAL_PANE"
fi

# --- LAUNCH TERMINAL ---
farm_launch_terminal \
    "farm-update" "$X_START" "$SESSION" 1.0