#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
cd "$(dirname "$0")"
source ../lib/config.sh

show_help() {
    cat << 'EOF'
Usage: ./node_session.sh <control|nvtop> [options]

Open tmux panes on eligible Linux farm nodes.

Options:
  -h, --help      Show this help message
  -y, --yes       Auto-include local workstation pane
      --local     Include local workstation pane
      --no-local  Exclude local workstation pane
EOF
}

MODE="${1:-}"
if [[ "$MODE" == "-h" || "$MODE" == "--help" || -z "$MODE" ]]; then
    show_help
    exit 0
fi
shift

AUTO_YES=0
FORCE_LOCAL=""
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            show_help
            exit 0
            ;;
        -y|--yes) AUTO_YES=1 ;;
        --local) FORCE_LOCAL="y" ;;
        --no-local) FORCE_LOCAL="n" ;;
        *) farm_die_unknown_option "$arg" show_help ;;
    esac
done

case "$MODE" in
    control)
        UI_TITLE="FARM CONTROL"
        PROMPT_TEXT="Include local workstation"
        SESSION="farm_control"
        REMOTE_PAYLOAD="'bash -l -c \"clear; exec bash\"'"
        LOCAL_CMD="bash -lc 'cd ~; exec bash'"
        LOCAL_TITLE="$FARM_LOCAL_NAME"
        WINDOW_TITLE="farm-control"
        WINDOW_SLEEP="1.2"
        SHOW_CHEATSHEET=1
        WINDOW_W=""
        WINDOW_H=""
        WINDOW_LAYOUT=""
        ;;
    nvtop)
        UI_TITLE="FARM NVTOP"
        PROMPT_TEXT="Include $FARM_LOCAL_NAME machine in monitor"
        SESSION="farm_nvtop"
        REMOTE_PAYLOAD="'nvtop'"
        LOCAL_CMD="nvtop; read -p 'nvtop exited. Press Enter to close.'"
        LOCAL_TITLE="$FARM_LOCAL_NAME"
        WINDOW_TITLE="farm-nvtop"
        WINDOW_SLEEP="1.0"
        SHOW_CHEATSHEET=0
        WINDOW_W="$FARM_NVTOP_WINDOW_W"
        WINDOW_H="$FARM_NVTOP_WINDOW_H"
        WINDOW_LAYOUT="tiled"
        ;;
    *)
        farm_print_error "Unknown mode: $MODE"
        echo ""
        show_help
        exit 1
        ;;
esac

"$FARM_SCRIPTS_DIR/lib/header.sh"
echo ""

X_START="$FARM_X_START"
farm_print_title "$UI_TITLE"

if [ "$FORCE_LOCAL" = "y" ]; then
    INCLUDE_LOCAL="y"
else
    INCLUDE_LOCAL="n"
fi

farm_tmux_reset_session "$SESSION"
farm_init_dual_boot_names

ELIGIBLE_NODES=()
for NODE in "${NODES[@]}"; do
    farm_get_node_os_status "$NODE" "assume"
    OS_STATUS=$?
    case "$OS_STATUS" in
        0)
            echo "$(farm_node_tag "$NODE") offline - skipped"
            ;;
        1)
            echo "$(farm_node_tag "$NODE") on Windows - skipped"
            ;;
        2)
            ELIGIBLE_NODES+=("$NODE")
            ;;
    esac
done

if [ ${#ELIGIBLE_NODES[@]} -eq 0 ]; then
    farm_print_warn "No eligible Linux nodes for $MODE session."
    exit 0
fi

for NODE in "${ELIGIBLE_NODES[@]}"; do
    farm_tmux_add_pane \
        "$SESSION" \
        "ssh -t -F ~/.ssh/config -o LogLevel=ERROR ${NODE} ${REMOTE_PAYLOAD}" \
        "NODE: ${NODE}"
done

if [[ "$INCLUDE_LOCAL" =~ ^[Yy]$ ]]; then
    farm_tmux_add_pane "$SESSION" "$LOCAL_CMD" "$LOCAL_TITLE"
fi

if [ -n "$WINDOW_LAYOUT" ]; then
    tmux select-layout -t "$SESSION" "$WINDOW_LAYOUT"
fi

farm_tmux_apply_config "$SESSION"
if [ "$SHOW_CHEATSHEET" -eq 1 ]; then
    farm_tmux_print_cheatsheet
fi

farm_launch_terminal "$WINDOW_TITLE" "$X_START" "$SESSION" "$WINDOW_SLEEP" "$WINDOW_W" "$WINDOW_H"
