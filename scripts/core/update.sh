#!/bin/bash
#  _____                         _
# |   __|___ ___ ___ ___ ___ ___| |_ _ _ ___ ___
# |  |  | -_| . | -_|   |_ -|  _|   | | |_ -|_ -|
# |_____|___|_  |___|_|_|___|___|_|_|___|___|___|
#           |___|
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
    echo -e '  \e[31m[!!!] REBOOT REQUIRED [!!!]\e[0m'; \
else \
    echo -e '  \e[32m[OK] No reboot necessary.\e[0m'; \
fi; \
echo '  ▸ update done'; \
echo '  Press Enter to exit.'; \
read"

# --- LOCAL COMMAND (passwordless sudo via /etc/sudoers.d/farm) ---
# Nodes stay on apt; the local workstation may be apt (Ubuntu) or dnf
# (Rocky), so the local pane picks its package manager at runtime.
# Rocky: needs-restarting -r (dnf-utils) exits 1 when a reboot is due.
LOCAL_CMD="if command -v apt >/dev/null 2>&1; then \
$REMOTE_CMD
else \
sudo dnf upgrade -y --refresh; \
if command -v needs-restarting >/dev/null 2>&1 && \
   ! needs-restarting -r >/dev/null 2>&1; then \
    echo -e '  \e[31m[!!!] REBOOT REQUIRED [!!!]\e[0m'; \
else \
    echo -e '  \e[32m[OK] No reboot necessary.\e[0m'; \
fi; \
echo '  ▸ update done'; \
echo '  Press Enter to exit.'; \
read; \
fi"

if [ "$FORCE_LOCAL" = "y" ]; then
    UPDATE_LOCAL="y"
else
    UPDATE_LOCAL="n"
fi

# --- CHECK NODE STATUS ---
echo ""
farm_print_section "Checking node status"
declare -A NODE_OS
N_UPDATE=0 N_WIN=0 N_OFF=0
for NODE in "${NODES[@]}"; do
    # Probe over ssh (the same channel the update runs on) rather than a
    # bare-name ping - see install_app.sh for why ping can disagree.
    farm_spin_start "checking $NODE"
    farm_get_node_os_status "$NODE" "ssh"
    NODE_OS[$NODE]=$?
    farm_spin_stop
    case ${NODE_OS[$NODE]} in
        0)
            echo "  $(farm_node_tag "$NODE") offline - skipped"
            (( N_OFF++ ))
            ;;
        1)
            echo "  $(farm_node_tag "$NODE") on Windows - skipped"
            print_windows_tasks "$NODE"
            (( N_WIN++ ))
            ;;
        2)
            if farm_is_dual_boot_node "$NODE"; then
                echo "  $(farm_node_tag "$NODE") on Linux - will update"
            else
                echo "  $(farm_node_tag "$NODE") online - will update"
            fi
            (( N_UPDATE++ ))
            ;;
    esac
done

if [[ "$UPDATE_LOCAL" =~ ^[Yy]$ ]]; then
    echo "  $(farm_node_tag "$FARM_LOCAL_NAME") local workstation - will update"
    (( N_UPDATE++ ))
else
    echo "  $(farm_node_tag "$FARM_LOCAL_NAME") local workstation - skipped (menu U / --local)"
fi

echo ""
farm_print_summary "$N_UPDATE to update ${FARM_G_SEP} $N_WIN on windows ${FARM_G_SEP} $N_OFF offline"
echo ""
if [ "$AUTO_YES" -eq 1 ]; then
    echo "  Auto-yes enabled: starting updates."
else
    if ! farm_press_any_or_q "Press any key to start, q to abort"; then
        echo "  Aborted."
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

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    farm_print_warn "No eligible machines - nothing to do."
    echo ""
    exit 0
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