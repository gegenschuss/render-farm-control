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

TARGET_VERSION=$(farm_install_target_version "$FILENAME_ONLY")

# Query the installed version of $MODE on a node ("" = local workstation).
# Echoes the raw version string (empty if not installed).
query_installed_version() {
    local node="$1"
    if [ -z "$node" ]; then
        if [ "$MODE" = "deadline" ]; then
            [ -f "$FARM_DEADLINECOMMAND" ] && "$FARM_DEADLINECOMMAND" --version 2>/dev/null
        else
            ls -1d /opt/hfs* 2>/dev/null | sort -V | tail -1
        fi
    else
        # -n: never read stdin, so these probes can't swallow the keystrokes
        # the user later types at the selection prompt.
        if [ "$MODE" = "deadline" ]; then
            ssh -n -F ~/.ssh/config -o LogLevel=ERROR "$node" \
                '[ -f "'"$FARM_DEADLINECOMMAND"'" ] && "'"$FARM_DEADLINECOMMAND"'" --version 2>/dev/null'
        else
            ssh -n -F ~/.ssh/config -o LogLevel=ERROR "$node" \
                'ls -1d /opt/hfs* 2>/dev/null | sort -V | tail -1'
        fi
    fi
}

# Print one pre-flight line for a node given its state + installed version.
print_state_line() {
    local label="$1" ver="$2" state="$3"
    case "$state" in
        uptodate)
            printf "  %-12s  ${FARM_C_OK}%-13s${FARM_C_RESET} ${FARM_C_OK}[up to date]${FARM_C_RESET}\n" \
                "$label:" "$ver" ;;
        update)
            printf "  %-12s  ${FARM_C_WARN}%-13s${FARM_C_RESET} ${FARM_C_WARN}[needs update -> %s]${FARM_C_RESET}\n" \
                "$label:" "$ver" "$TARGET_VERSION" ;;
        notinstalled)
            printf "  %-12s  ${FARM_C_ERR}%-13s${FARM_C_RESET} ${FARM_C_WARN}[install -> %s]${FARM_C_RESET}\n" \
                "$label:" "not installed" "$TARGET_VERSION" ;;
        offline)
            printf "  %-12s  ${FARM_C_WARN}OFFLINE${FARM_C_RESET}\n" "$label:" ;;
        windows)
            printf "  %-12s  ${FARM_C_WARN}WINDOWS (skipping)${FARM_C_RESET}\n" "$label:" ;;
        *)
            printf "  %-12s  %-13s ${FARM_C_WARN}[unknown version]${FARM_C_RESET}\n" "$label:" "${ver:-?}" ;;
    esac
}

# Candidate target arrays (parallel): name, is-local flag, version, state.
CAND_NAME=() CAND_LOCAL=() CAND_VER=() CAND_STATE=()

# --- Local workstation ---
LOCAL_RAW=$(query_installed_version "")
LOCAL_VER=$(farm_extract_version "$LOCAL_RAW")
LOCAL_STATE=$(farm_install_classify "$LOCAL_VER" "$TARGET_VERSION")
print_state_line "$FARM_LOCAL_NAME" "$LOCAL_VER" "$LOCAL_STATE"
CAND_NAME+=("$FARM_LOCAL_NAME"); CAND_LOCAL+=("1")
CAND_VER+=("$LOCAL_VER"); CAND_STATE+=("$LOCAL_STATE")

# --- Farm nodes ---
declare -A NODE_OS
for node in "${NODES[@]}"; do
    # Probe over ssh (the same channel the install runs on) rather than a
    # bare-name ping. Pinging the hostname can resolve through a different path
    # than the ssh HostName (Tailscale/DNS vs LAN, or a stale /etc/hosts entry),
    # so a node could ping-up while ssh is down (or vice versa) and get wrongly
    # included/skipped for the install.
    farm_spin_start "checking $node"
    farm_get_node_os_status "$node" "ssh"
    NODE_OS[$node]=$?
    case ${NODE_OS[$node]} in
        0) farm_spin_stop; print_state_line "$node" "" "offline" ;;
        1) farm_spin_stop; print_state_line "$node" "" "windows" ;;
        2)
            raw=$(query_installed_version "$node")
            ver=$(farm_extract_version "$raw")
            state=$(farm_install_classify "$ver" "$TARGET_VERSION")
            farm_spin_stop
            print_state_line "$node" "$ver" "$state"
            CAND_NAME+=("$node"); CAND_LOCAL+=("0")
            CAND_VER+=("$ver"); CAND_STATE+=("$state")
            ;;
    esac
done

echo ""
printf "  %-12s  ${FARM_C_NODE}%s${FARM_C_RESET}\n" "Installing:" "$FILENAME_ONLY"
printf "  %-12s  ${FARM_C_NODE}%s${FARM_C_RESET}\n" "Target ver:" "${TARGET_VERSION:-unknown}"
echo ""

# --- Selection ---------------------------------------------------------------
farm_print_section "Select targets to install"

# Default selection = everything that needs updating (or isn't installed yet).
DEFAULT_SEL=()
for i in "${!CAND_NAME[@]}"; do
    case "${CAND_STATE[$i]}" in
        update|notinstalled|unknown) DEFAULT_SEL+=("$i") ;;
    esac
done

for i in "${!CAND_NAME[@]}"; do
    tag=""
    case "${CAND_STATE[$i]}" in
        uptodate)     tag="${FARM_C_OK}up to date${FARM_C_RESET}" ;;
        update)       tag="${FARM_C_WARN}needs update${FARM_C_RESET}" ;;
        notinstalled) tag="${FARM_C_WARN}not installed${FARM_C_RESET}" ;;
        *)            tag="unknown" ;;
    esac
    local_mark=""; [ "${CAND_LOCAL[$i]}" = "1" ] && local_mark=" (local)"
    printf "  [%d] %-18s %-13s %b\n" \
        "$((i+1))" "${CAND_NAME[$i]}${local_mark}" "${CAND_VER[$i]:-—}" "$tag"
done
echo ""
if [ ${#DEFAULT_SEL[@]} -gt 0 ]; then
    names=""
    for i in "${DEFAULT_SEL[@]}"; do names+="${names:+, }${CAND_NAME[$i]}"; done
    echo "  Default (update-only): $names"
else
    echo "  All targets are already up to date."
fi
farm_prompt_rule
echo "  [Enter]=update-only   a=all   numbers e.g. 1,3,5=manual   q=cancel"
read -p "> " SEL
echo ""

case "$SEL" in
    q|Q) echo "Aborted."; exit 0 ;;
    a|A) SELECTED=("${!CAND_NAME[@]}") ;;
    "")  SELECTED=("${DEFAULT_SEL[@]}") ;;
    *)
        SELECTED=()
        for tok in ${SEL//,/ }; do
            if [[ "$tok" =~ ^[0-9]+$ ]] && [ "$tok" -ge 1 ] \
               && [ "$tok" -le "${#CAND_NAME[@]}" ]; then
                SELECTED+=("$((tok-1))")
            else
                farm_print_warn "Ignoring invalid selection: $tok"
            fi
        done
        ;;
esac

if [ ${#SELECTED[@]} -eq 0 ]; then
    echo "Nothing selected — nothing to install."
    exit 0
fi

# Map selection -> remote node list + local flag.
ELIGIBLE_NODES=()
INSTALL_LOCAL="n"
for i in "${SELECTED[@]}"; do
    if [ "${CAND_LOCAL[$i]}" = "1" ]; then
        INSTALL_LOCAL="y"
    else
        ELIGIBLE_NODES+=("${CAND_NAME[$i]}")
    fi
done

echo "Will install ${FILENAME_ONLY} on:"
for i in "${SELECTED[@]}"; do
    lm=""; [ "${CAND_LOCAL[$i]}" = "1" ] && lm=" (local)"
    printf "  - %s%s\n" "${CAND_NAME[$i]}" "$lm"
done
farm_prompt_rule
read -p "Proceed? (y/n): " PROCEED
echo ""
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
    HOUDINI_SCRIPT=$(farm_install_build_houdini_cmd \
        "$FILENAME_ONLY" "$SEARCH_DIR" "$INSTALL_DIR")

    # The generated script contains single/double quotes, newlines and raw ANSI
    # escapes. Embedding it verbatim inside ssh "..."/bash -c '...' corrupts the
    # quoting and the tmux pane dies instantly ("server exited unexpectedly").
    # base64-encode it the same way the deadline path does so the wrapper only
    # ever sees a safe [A-Za-z0-9+/=] payload.
    B64_HOUDINI=$(echo "$HOUDINI_SCRIPT" | base64 -w 0)
    REMOTE_FINAL_CMD="bash -c 'echo $B64_HOUDINI | base64 -d | bash'"
    LOCAL_SCRIPT="echo $B64_HOUDINI | base64 -d | bash"
fi

farm_print_section "Launching tmux session"
echo "Session:"
echo "    $SESSION"
echo ""
echo "Targets:"
[ ${#ELIGIBLE_NODES[@]} -gt 0 ] && echo "  ${ELIGIBLE_NODES[*]}"
[[ "$INSTALL_LOCAL" =~ ^[Yy]$ ]] && echo "  $FARM_LOCAL_NAME (local)"
echo ""
farm_tmux_reset_session "$SESSION"

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
