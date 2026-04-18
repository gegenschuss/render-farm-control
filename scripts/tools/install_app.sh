#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
cd "$(dirname "$0")"
source ../lib/config.sh
farm_require_bash4 "install_app.sh"
source ../lib/install_lib.sh

show_help() {
    cat << 'EOF'
Usage: ./install_app.sh <deadline|houdini> [options]

Install latest package on eligible Linux farm nodes.

Options:
  -h, --help    Show this help message
EOF
}

MODE="${1:-}"
if [[ "$MODE" == "-h" || "$MODE" == "--help" || -z "$MODE" ]]; then
    show_help
    exit 0
fi
shift

case "$MODE" in
    deadline)
        APP_TITLE="DEADLINE FARM INSTALLER"
        SEARCH_DIR="${FARM_INSTALL_DIR_DEADLINE:?Set FARM_INSTALL_DIR_DEADLINE in config/secrets.sh}"
        FILE_GLOB="Deadline-*-linux-installers.tar"
        SEARCH_TEXT="Searching latest Deadline version"
        SESSION="farm_install_deadline"
        WINDOW_TITLE="farm-deadline"
        REMOTE_INSTALL_DIR='$HOME/deadline_installer'
        ;;
    houdini)
        APP_TITLE="HOUDINI FARM INSTALLER"
        SEARCH_DIR="${FARM_INSTALL_DIR_HOUDINI:?Set FARM_INSTALL_DIR_HOUDINI in config/secrets.sh}"
        FILE_GLOB="houdini-*-linux_x86_64_gcc*.tar.gz"
        SEARCH_TEXT="Searching latest Houdini version"
        SESSION="farm_install_houdini"
        WINDOW_TITLE="farm-houdini"
        INSTALL_DIR='$HOME/houdini_installer'
        ;;
    *)
        farm_print_error "Unknown install mode: $MODE"
        echo ""
        show_help
        exit 1
        ;;
esac

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_help
    exit 0
fi

"$FARM_SCRIPTS_DIR/lib/header.sh"
echo ""

X_START="$FARM_X_START"
farm_print_title "$APP_TITLE"

echo "Do you want to copy the archive to:"
echo "  $SEARCH_DIR?"
farm_prompt_rule
read -p "(y/n, q=cancel): " COPY_ARCHIVE
echo ""
if [[ "$COPY_ARCHIVE" == "q" || "$COPY_ARCHIVE" == "Q" ]]; then
    echo "Aborted."
    exit 0
fi
if [[ "$COPY_ARCHIVE" =~ ^[Yy]$ ]]; then
    echo "Copy from which directory?"
    farm_prompt_rule
    read -p "(default: ~/Downloads): " COPY_SOURCE
    if [[ "$COPY_SOURCE" == "q" || "$COPY_SOURCE" == "Q" ]]; then
        echo "Aborted."
        exit 0
    fi
    COPY_SOURCE="${COPY_SOURCE:-$HOME/Downloads}"
    COPY_SOURCE="${COPY_SOURCE/#\~/$HOME}"
    echo ""
    echo "Searching for latest package in:"
    echo "  $COPY_SOURCE"
    echo ""
    if [ ! -d "$COPY_SOURCE" ]; then
        farm_print_error "Install directory not found: $COPY_SOURCE"
        echo "  Check that the network share is mounted."
        exit 1
    fi
    COPY_TAR=$(ls -1 "$COPY_SOURCE"/$FILE_GLOB 2>/dev/null | sort -V | tail -n 1)
    if [ -z "$COPY_TAR" ]; then
        echo "  ERROR: No matching archive found!"
        echo "  Location: $COPY_SOURCE"
        echo "  Aborting."
        echo ""
        exit 1
    fi
    echo "  Found: $(basename "$COPY_TAR")"
    echo ""
    echo "  Copying to:"
    echo "    $SEARCH_DIR"
    echo ""
    cp "$COPY_TAR" "$SEARCH_DIR/" || {
        echo "  ERROR: Copy FAILED! Aborting."
        echo ""
        exit 1
    }
    echo "  Copy successful."
    echo ""
fi

farm_print_section "$SEARCH_TEXT"
echo "Location:"
echo "  $SEARCH_DIR"
echo ""
if [ ! -d "$SEARCH_DIR" ]; then
    farm_print_error "Install directory not found: $SEARCH_DIR"
    echo "  Check that the network share is mounted."
    exit 1
fi
LATEST_TAR=$(ls -1 "$SEARCH_DIR"/$FILE_GLOB 2>/dev/null | sort -V | tail -n 1)
if [ -z "$LATEST_TAR" ]; then
    echo "  ERROR: No matching package found!"
    echo ""
    exit 1
fi
FILENAME_ONLY=$(basename "$LATEST_TAR")
echo "  Found:"
echo "    $FILENAME_ONLY"
echo ""

farm_print_section "Pre-flight checks"

if [ "$MODE" = "deadline" ]; then
    farm_install_check_state "$MODE" "$FARM_LOCAL_NAME" \
        "[ -f \"$FARM_DEADLINECOMMAND\" ] && \"$FARM_DEADLINECOMMAND\" --version 2>/dev/null || echo 'not installed'"
else
    farm_install_check_state "$MODE" "$FARM_LOCAL_NAME" \
        "ls -1d /opt/hfs* 2>/dev/null | sort -V | tail -1"
fi

declare -A NODE_OS
for node in "${NODES[@]}"; do
    farm_get_node_os_status "$node" "ping"
    NODE_OS[$node]=$?
    case ${NODE_OS[$node]} in
        0)
            printf "  %-12s  ${FARM_C_WARN}OFFLINE${FARM_C_RESET}\n" "$node:"
            ;;
        1)
            printf "  %-12s  ${FARM_C_WARN}WINDOWS (skipping)${FARM_C_RESET}\n" "$node:"
            ;;
        2)
            if [ "$MODE" = "deadline" ]; then
                farm_install_check_state "$MODE" "$node" \
                    "ssh -F ~/.ssh/config -o LogLevel=ERROR $node '[ -f \"$FARM_DEADLINECOMMAND\" ] && \"$FARM_DEADLINECOMMAND\" --version 2>/dev/null || echo not installed'"
            else
                farm_install_check_state "$MODE" "$node" \
                    "ssh -F ~/.ssh/config -o LogLevel=ERROR $node 'ls -1d /opt/hfs* 2>/dev/null | sort -V | tail -1'"
            fi
            ;;
    esac
done

echo ""
printf "  %-12s  ${FARM_C_NODE}%s${FARM_C_RESET}\n" "Installing:" "$FILENAME_ONLY"
echo ""

echo "Install on local workstation as well?"
farm_prompt_rule
read -p "(y/n, q=cancel): " INSTALL_LOCAL
echo ""
if [[ "$INSTALL_LOCAL" == "q" || "$INSTALL_LOCAL" == "Q" ]]; then
    echo "Aborted."
    exit 0
fi

echo "Proceed with installation on all nodes?"
farm_prompt_rule
read -p "(y/n, q=cancel): " PROCEED
echo ""
if [[ "$PROCEED" == "q" || "$PROCEED" == "Q" ]]; then
    echo "Aborted."
    exit 0
fi
if [[ ! "$PROCEED" =~ ^[Yy]$ ]]; then
    echo "  Aborted."
    echo ""
    exit 0
fi

if [ "$MODE" = "deadline" ]; then
    REMOTE_SCRIPT=$(farm_install_build_deadline_remote_script \
        "$FILENAME_ONLY" "$SEARCH_DIR" "$REMOTE_INSTALL_DIR")
    LOCAL_SCRIPT=$(farm_install_build_deadline_local_script \
        "$FARM_LOCAL_NAME" "$FILENAME_ONLY" "$SEARCH_DIR" "$REMOTE_INSTALL_DIR")

    B64_REMOTE=$(echo "$REMOTE_SCRIPT" | base64 -w 0)
    REMOTE_FINAL_CMD="bash -c 'echo $B64_REMOTE | base64 -d | bash'"
else
    REMOTE_FINAL_CMD=$(farm_install_build_houdini_cmd \
        "$FILENAME_ONLY" "$SEARCH_DIR" "$INSTALL_DIR")
    LOCAL_SCRIPT="$REMOTE_FINAL_CMD"
fi

farm_print_section "Launching tmux session"
echo "Session:"
echo "    $SESSION"
echo ""
echo "Nodes:"
echo "  ${NODES[*]}"
echo ""
farm_tmux_reset_session "$SESSION"

ELIGIBLE_NODES=()
for node in "${NODES[@]}"; do
    if [ "${NODE_OS[$node]}" = "2" ]; then
        ELIGIBLE_NODES+=("$node")
    fi
done

if [ ${#ELIGIBLE_NODES[@]} -eq 0 ]; then
    farm_print_warn "No eligible Linux nodes for $MODE install."
    exit 0
fi

for NODE in "${ELIGIBLE_NODES[@]}"; do
    farm_tmux_add_pane \
        "$SESSION" \
        "ssh -t -F ~/.ssh/config -o LogLevel=ERROR ${NODE} \"$REMOTE_FINAL_CMD\"" \
        "NODE: ${NODE}" \
        "1080" "1920"
done

if [[ "$INSTALL_LOCAL" =~ ^[Yy]$ ]]; then
    farm_tmux_add_pane "$SESSION" "bash -c '$LOCAL_SCRIPT'" "$FARM_LOCAL_NAME"
fi

farm_tmux_apply_config "$SESSION"
farm_launch_terminal "$WINDOW_TITLE" "$X_START" "$SESSION" 2.0

echo ""
