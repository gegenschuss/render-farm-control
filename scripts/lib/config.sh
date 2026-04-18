#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
# ============================================
#   farm - SHARED CONFIG
#   Requires: config/secrets.sh (see secrets.example.sh)
#
#   Usage in any farm script:
#     cd "$(dirname "$0")"
#     source ../lib/config.sh
#
#   Available functions:
#     detect_node_os "$NODE"
#     print_windows_tasks "$NODE"
#     check_linux_node_health "$NODE"
#     farm_tmux_apply_config "$SESSION"
#     farm_tmux_print_cheatsheet
#     farm_launch_terminal "$TITLE" "$X_START" "$SESSION" "$SLEEP"
# ============================================

# --- USER CUSTOMIZATION ---
# All user-specific values (node definitions, MAC addresses, etc.)
# live in config/secrets.sh. See secrets.example.sh for the template.
#
# FARM_NODE_DEFS record format:
#   NAME|MAC|BIOS_GUID|LINUX_WAIT|WIN_USER
#
# Field guide:
#   NAME       -> ssh host prefix (Linux host is NAME, Windows host is NAME-win)
#   MAC        -> used for Wake-on-LAN (use colon format; dashes are auto-normalized)
#   BIOS_GUID  -> required only for dual-boot machines (Windows -> Linux boot target)
#   LINUX_WAIT -> optional wait (seconds) before Linux ping checks; default is 60
#   WIN_USER   -> Windows user hint for safety prompts on dual-boot machines
#
# Linux-only node example:
#   "node-01|AA:BB:CC:DD:EE:01|||"
# Dual-boot node example:
#   "node-02|AA:BB:CC:DD:EE:02|{your-linux-boot-guid}|60|winuser"
#
# How to get BIOS_GUID from Windows via SSH (PowerShell):
#   ssh -F ~/.ssh/config node-02-win \
#     "powershell -NoProfile -Command \"bcdedit /enum firmware /v\""
# Then copy the Linux/Ubuntu firmware entry identifier and paste that
# GUID (with braces) into BIOS_GUID.
#
# Optional user overrides (usually left as-is):
#   FARM_LOCAL_NAME
#   FARM_DEADLINECOMMAND  (path to deadlinecommand binary)
FARM_DEADLINECOMMAND="${FARM_DEADLINECOMMAND:-/opt/Thinkbox/Deadline10/bin/deadlinecommand}"

# Load user-specific node definitions and secrets.
# secrets.sh lives in config/ (two levels up + config/).
_FARM_SECRETS_FILE="${FARM_SECRETS_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/config/secrets.sh}"
if [ ! -f "$_FARM_SECRETS_FILE" ]; then
    echo "ERROR: secrets.sh not found at: $_FARM_SECRETS_FILE" >&2
    echo "Copy secrets.example.sh to secrets.sh and fill in your values." >&2
    exit 1
fi
source "$_FARM_SECRETS_FILE"

# Derived structures for scripts (do not edit manually).
NODES=()
DUAL_BOOT_NODES=()
declare -A FARM_NODE_MAC=()
declare -A FARM_NODE_BIOS_GUID=()
declare -A FARM_NODE_LINUX_WAIT=()
declare -A FARM_NODE_WIN_USER=()

farm_init_node_inventory() {
    local def name mac bios_guid linux_wait win_user

    NODES=()
    DUAL_BOOT_NODES=()
    FARM_NODE_MAC=()
    FARM_NODE_BIOS_GUID=()
    FARM_NODE_LINUX_WAIT=()
    FARM_NODE_WIN_USER=()

    for def in "${FARM_NODE_DEFS[@]}"; do
        IFS='|' read -r name mac bios_guid linux_wait win_user <<< "$def"
        [ -z "$name" ] && continue

        # Normalize MAC for wakeonlan compatibility.
        mac="${mac//-/:}"
        mac="${mac^^}"

        NODES+=("$name")
        FARM_NODE_MAC["$name"]="$mac"
        FARM_NODE_BIOS_GUID["$name"]="$bios_guid"
        FARM_NODE_LINUX_WAIT["$name"]="${linux_wait:-60}"
        FARM_NODE_WIN_USER["$name"]="$win_user"

        if [ -n "$bios_guid" ]; then
            DUAL_BOOT_NODES+=(
                "$name|$bios_guid|${FARM_NODE_LINUX_WAIT[$name]}|$win_user"
            )
        fi
    done
}

farm_get_node_mac() {
    local node="$1"
    echo "${FARM_NODE_MAC[$node]}"
}

# --- HOST PLATFORM DETECTION ---
FARM_OS="linux"
if [[ "$(uname -s)" == "Darwin" ]]; then
    FARM_OS="mac"
fi

# Local workstation label (override by exporting FARM_LOCAL_NAME).
FARM_LOCAL_NAME="${FARM_LOCAL_NAME:-$(hostname -s 2>/dev/null || hostname)}"

# --- SHARED PATHS ---
# FARM_BASE_DIR = project root (parent of scripts/).
# FARM_SCRIPTS_DIR = scripts/ subfolder where all farm tools live.
FARM_BASE_DIR="${FARM_BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
FARM_SCRIPTS_DIR="${FARM_SCRIPTS_DIR:-$FARM_BASE_DIR/scripts}"
FARM_X_START="${FARM_X_START:-3840}"
FARM_NVTOP_WINDOW_W="${FARM_NVTOP_WINDOW_W:-3440}"
FARM_NVTOP_WINDOW_H="${FARM_NVTOP_WINDOW_H:-1200}"

# ============================================

farm_init_node_inventory

# --- TERMINAL OUTPUT HELPERS ---
# Keep script output consistent across all farm tools.
FARM_C_RESET='\033[0m'
FARM_C_TITLE='\033[1;36m'
FARM_C_SECTION='\033[1;34m'
FARM_C_RULE='\033[1;34m'
FARM_C_OK='\033[1;32m'
FARM_C_WARN='\033[1;33m'
FARM_C_ERR='\033[1;31m'
FARM_C_NODE='\033[1;36m'
FARM_UI_WIDTH=60
FARM_VERSION="${FARM_VERSION:-2.1}"

farm_disable_colors() {
    FARM_C_RESET=''
    FARM_C_TITLE=''
    FARM_C_SECTION=''
    FARM_C_RULE=''
    FARM_C_OK=''
    FARM_C_WARN=''
    FARM_C_ERR=''
    FARM_C_NODE=''
}

farm_apply_random_header_theme() {
    local title_colors=(
        '\033[1;36m' # cyan
        '\033[1;35m' # magenta
        '\033[1;33m' # yellow
        '\033[1;32m' # green
    )
    local section_colors=(
        '\033[1;34m'
        '\033[1;36m'
        '\033[1;35m'
        '\033[1;33m'
    )
    local rule_colors=(
        '\033[1;34m'
        '\033[1;36m'
        '\033[1;35m'
        '\033[1;33m'
        '\033[1;32m'
    )

    local title_idx=$(( RANDOM % ${#title_colors[@]} ))
    local section_idx=$(( RANDOM % ${#section_colors[@]} ))
    local rule_idx=$(( RANDOM % ${#rule_colors[@]} ))

    FARM_C_TITLE="${title_colors[$title_idx]}"
    FARM_C_SECTION="${section_colors[$section_idx]}"
    FARM_C_RULE="${rule_colors[$rule_idx]}"

    # Ensure the rule color is always different from the title color.
    if [[ "$FARM_C_RULE" == "$FARM_C_TITLE" ]]; then
        rule_idx=$(( (rule_idx + 1) % ${#rule_colors[@]} ))
        FARM_C_RULE="${rule_colors[$rule_idx]}"
    fi
}

farm_apply_random_header_theme

farm_print_rule() {
    local width="${1:-$FARM_UI_WIDTH}"
    printf "${FARM_C_RULE}%0.s=${FARM_C_RESET}" $(seq 1 "$width")
    echo ""
}

farm_print_title() {
    local TEXT="$1"
    farm_print_rule
    echo -e "${FARM_C_TITLE}    ${TEXT}${FARM_C_RESET}"
    farm_print_rule
    echo ""
}

farm_print_section() {
    local TEXT="$1"
    echo -e "${FARM_C_SECTION}    --- ${TEXT} ---${FARM_C_RESET}"
    echo ""
}

farm_print_ok() {
    echo -e "${FARM_C_OK}$*${FARM_C_RESET}"
}

farm_print_warn() {
    echo -e "${FARM_C_WARN}$*${FARM_C_RESET}"
}

farm_print_error() {
    echo -e "${FARM_C_ERR}$*${FARM_C_RESET}"
}

farm_require_cmd() {
    local cmd="$1"
    local hint="$2"
    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi
    farm_print_error "Missing dependency: $cmd"
    if [ -n "$hint" ]; then
        echo "  Hint: $hint"
    fi
    return 1
}

farm_require_bash4() {
    local context="${1:-this script}"
    if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
        farm_print_error "$context requires Bash 4+."
        echo "Current bash: ${BASH_VERSION:-unknown}"
        echo "Tip: run on Linux host or newer bash."
        exit 1
    fi
}

farm_ssh() {
    # Shared SSH defaults used across scripts.
    ssh -F ~/.ssh/config -o LogLevel=ERROR "$@"
}

farm_ssh_batch() {
    ssh -F ~/.ssh/config -o BatchMode=yes -o LogLevel=ERROR "$@"
}

farm_ssh_tty() {
    ssh -t -F ~/.ssh/config -o LogLevel=ERROR "$@"
}

farm_ssh_timeout() {
    local timeout="${1:-3}"
    shift
    ssh -F ~/.ssh/config -o ConnectTimeout="$timeout" -o LogLevel=ERROR "$@"
}

farm_die_unknown_option() {
    local arg="$1"
    local help_fn="$2"
    farm_print_error "Unknown option: $arg"
    echo ""
    "$help_fn"
    exit 1
}

farm_prompt_rule() {
    local width="${1:-60}"
    local line
    line=$(printf "%*s" "$width" "" | tr " " "-")
    echo ""
    echo -e "${FARM_C_WARN}${line}${FARM_C_RESET}"
    echo ""
}

farm_prompt_heading() {
    local text="$1"
    echo -e "${FARM_C_WARN}${text}${FARM_C_RESET}"
}

farm_prompt_local_choice() {
    local no_local="$1"
    local with_local="$2"
    local auto_yes="$3"
    local prompt="$4"
    local auto_yes_default="${5:-n}"

    if [ "$no_local" -eq 1 ]; then
        FARM_LOCAL_CHOICE="n"
    elif [ "$with_local" -eq 1 ]; then
        FARM_LOCAL_CHOICE="y"
    elif [ "$auto_yes" -eq 1 ]; then
        FARM_LOCAL_CHOICE="$auto_yes_default"
    else
        farm_prompt_heading "$prompt"
        echo "(press q to cancel)"
        farm_prompt_rule
        read -n 1 -r -p "> " FARM_LOCAL_CHOICE
        echo ""
        if [[ "$FARM_LOCAL_CHOICE" == "q" || "$FARM_LOCAL_CHOICE" == "Q" ]]; then
            echo "Aborted."
            exit 0
        fi
    fi
}

prompt_inline_yn_with_cancel() {
    local prompt_text="$1"
    local answer
    printf "%s (y/n)? " "$prompt_text"
    read -n 1 -s -r answer
    echo "$answer"
    if [[ "$answer" == "q" || "$answer" == "Q" ]]; then
        echo "Aborted."
        exit 0
    fi
    FARM_PROMPT_ANSWER="$answer"
}

farm_confirm_yn() {
    local prompt="$1"
    local auto_yes="${2:-0}"
    local default_answer="${3:-n}"
    local reply

    if [ "$auto_yes" -eq 1 ]; then
        reply="y"
    else
        farm_prompt_rule
        read -n 1 -r -p "$prompt" reply
        echo ""
    fi

    if [[ "$reply" == "q" || "$reply" == "Q" ]]; then
        return 1
    fi

    if [[ "$reply" =~ ^[Yy]$ ]]; then
        return 0
    fi

    if [[ "$reply" =~ ^[Nn]$ ]]; then
        return 1
    fi

    [[ "$default_answer" =~ ^[Yy]$ ]]
}

farm_press_any_or_q() {
    local prompt="$1"
    farm_prompt_rule
    echo "$prompt"
    read -n 1 -s key
    if [[ "$key" == "q" || "$key" == "Q" ]]; then
        return 1
    fi
    return 0
}

farm_countdown_with_pause() {
    local total_seconds="$1"
    local label="${2:-Countdown}"
    local is_paused=0
    local key mins secs

    while [ "$total_seconds" -gt 0 ]; do
        mins=$((total_seconds / 60))
        secs=$((total_seconds % 60))

        if [[ "$is_paused" -eq 1 ]]; then
            printf "\r%s %02d:%02d [PAUSED] (any key to resume, q=cancel) " \
                "$label" "$mins" "$secs"
        else
            printf "\r%s %02d:%02d (any key to pause, q=cancel)          " \
                "$label" "$mins" "$secs"
        fi

        read -t 1 -n 1 -s key
        if [[ "$key" == "q" || "$key" == "Q" ]]; then
            echo ""
            return 1
        elif [[ -n "$key" ]]; then
            if [[ "$is_paused" -eq 0 ]]; then
                is_paused=1
            else
                is_paused=0
            fi
        fi

        if [[ "$is_paused" -eq 0 && -z "$key" ]]; then
            ((total_seconds--))
        fi
    done

    echo ""
    return 0
}

farm_print_node_summary_line() {
    local node="$1"
    local message="$2"
    echo " $(farm_color_node_name "$node"): $message"
}

farm_color_node_name() {
    local node="$1"
    echo -e "${FARM_C_NODE}${node}${FARM_C_RESET}"
}

farm_node_tag() {
    local node="$1"
    echo -e "[${FARM_C_NODE}${node}${FARM_C_RESET}]"
}

# Shared payload for remote Linux shutdown action.
FARM_REMOTE_SHUTDOWN_CMD="sudo poweroff"
FARM_DUAL_BOOT_NAMES=""

farm_init_dual_boot_names() {
    FARM_DUAL_BOOT_NAMES=$(printf '%s\n' "${DUAL_BOOT_NODES[@]}" | cut -d'|' -f1)
}

farm_is_dual_boot_node() {
    local node="$1"
    if [ -z "$FARM_DUAL_BOOT_NAMES" ]; then
        farm_init_dual_boot_names
    fi
    echo "$FARM_DUAL_BOOT_NAMES" | grep -qx "$node"
}

# Returns:
# 0 = offline/unreachable
# 1 = Windows (dual-boot only)
# 2 = Linux/eligible
farm_get_node_os_status() {
    local node="$1"
    local non_dual_strategy="${2:-ping}"

    if farm_is_dual_boot_node "$node"; then
        detect_node_os "$node"
        return $?
    fi

    case "$non_dual_strategy" in
        assume)
            return 2
            ;;
        ping)
            if ping -c 1 -W 1 "$node" &>/dev/null; then
                return 2
            fi
            return 0
            ;;
        ssh)
            if ssh -F ~/.ssh/config -o ConnectTimeout=3 -o LogLevel=ERROR \
                "$node" "echo ok" &>/dev/null; then
                return 2
            fi
            return 0
            ;;
        ssh_or_ping)
            if ssh -F ~/.ssh/config -o ConnectTimeout=3 -o LogLevel=ERROR \
                "$node" "echo ok" &>/dev/null; then
                return 2
            fi
            if ping -c 1 -W 1 "$node" &>/dev/null; then
                return 2
            fi
            return 0
            ;;
        *)
            farm_print_error "Invalid non-dual strategy: $non_dual_strategy"
            return 0
            ;;
    esac
}

# --- DETECT DUAL BOOT NODE OS ---
# Returns:
# 0 = offline
# 1 = windows
# 2 = linux
detect_node_os() {
    local NAME=$1

    # Check Windows first
    if ssh -F ~/.ssh/config -o BatchMode=yes -o ConnectTimeout=3 -o LogLevel=ERROR \
           "${NAME}-win" "echo ok" &>/dev/null; then

        OS_CHECK=$(ssh -F ~/.ssh/config -o BatchMode=yes -o ConnectTimeout=3 -o LogLevel=ERROR \
            "${NAME}-win" \
            "powershell -Command \"\$env:OS\"" 2>/dev/null)

        if echo "$OS_CHECK" | grep -qi "Windows"; then
            return 1
        fi
    fi

    # Check Linux
    if ssh -F ~/.ssh/config -o BatchMode=yes -o ConnectTimeout=3 -o LogLevel=ERROR \
           "$NAME" "echo ok" &>/dev/null; then
        return 2
    fi

    return 0
}

# --- WINDOWS TASK INSPECTION (shared) ---
farm_get_windows_tasks() {
    local NAME=$1
    ssh -F ~/.ssh/config -o BatchMode=yes -o LogLevel=ERROR \
        "${NAME}-win" \
        'powershell -Command "$apps = @(\"Photoshop\",\"Illustrator\",\"AfterFX\",\"Adobe Premiere Pro\",\"reaper\"); Get-Process -ErrorAction SilentlyContinue | Where-Object { $apps -contains $_.Name } | Select-Object -ExpandProperty Name | Sort-Object -Unique"' \
        2>/dev/null | tr -d '\r'
}

print_windows_tasks() {
    local NAME=$1

    echo "$(farm_node_tag "$NAME") checking important Windows tasks (Premiere, Illustrator, Photoshop, After Effects, Reaper)..."

    TASKS=$(farm_get_windows_tasks "$NAME")

    if [ -z "$TASKS" ]; then
        echo "$(farm_node_tag "$NAME") no important Windows tasks running."
    else
        echo "$(farm_node_tag "$NAME") important Windows tasks running:"
        echo "$TASKS" | while read -r TASK; do
            [ -n "$TASK" ] && echo "  - $TASK"
        done
    fi
}

# --- CHECK LINUX NODE HEALTH ---
# Returns:
# 0 = all clear
# 1 = warnings found
farm_get_update_blockers() {
    local NODE=$1
    ssh -F ~/.ssh/config -o ConnectTimeout=3 -o LogLevel=ERROR "$NODE" '
ps -eo comm,args | awk '"'"'
    $1 == "apt-get" { print; found=1; next }
    ($1 == "unattended-upgrade" || $1 == "unattended-upgrades") { print; found=1; next }
    ($1 == "dpkg" && $0 ~ /--configure|--unpack|--install/) { print; found=1; next }
    END { if (!found) exit 1 }
'"'"'
' 2>/dev/null
}

check_update_blockers() {
    local NODE=$1
    local BLOCKERS

    BLOCKERS=$(farm_get_update_blockers "$NODE")
    FARM_LAST_UPDATE_BLOCKERS="$BLOCKERS"

    if [ -n "$BLOCKERS" ]; then
        return 1
    fi
    return 0
}

check_linux_node_health() {
    local NODE=$1
    local WARNINGS=()

    # Check for active package update/install work.
    APT_RUNNING=$(farm_get_update_blockers "$NODE")
    if [ -n "$APT_RUNNING" ]; then
        WARNINGS+=("APT/DPKG update in progress")
    fi

    # Check for high CPU usage (above 80%)
    CPU_USAGE=$(ssh -F ~/.ssh/config -o ConnectTimeout=3 -o LogLevel=ERROR \
        $NODE "top -bn1 | grep 'Cpu(s)' | awk '{print \$2}' | cut -d. -f1" 2>/dev/null)
    if [ -n "$CPU_USAGE" ] && [ "$CPU_USAGE" -gt 80 ] 2>/dev/null; then
        WARNINGS+=("High CPU usage: ${CPU_USAGE}%")
    fi

    # Check for high GPU usage
    GPU_USAGE=$(ssh -F ~/.ssh/config -o ConnectTimeout=3 -o LogLevel=ERROR \
        $NODE "nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | awk '{sum+=\$1} END {print sum/NR}' | cut -d. -f1" 2>/dev/null)
    if [ -n "$GPU_USAGE" ] && [ "$GPU_USAGE" -gt 80 ] 2>/dev/null; then
        WARNINGS+=("High GPU usage: ${GPU_USAGE}%")
    fi

    if [ ${#WARNINGS[@]} -gt 0 ]; then
        farm_print_warn "WARNING: $NODE has active processes!"
        for W in "${WARNINGS[@]}"; do
            echo "   - $W"
        done
        return 1
    fi

    return 0
}

farm_tmux_apply_config() {
    local SESSION="$1"

    # --- PANE BORDERS ---
    tmux set-option -g pane-border-status top
    tmux set-option -g pane-border-format \
        " #[bold]#{pane_title} "

    # --- STATUS BAR RIGHT ---
    tmux set-option -g status-right-length 80
    tmux set-option -g status-right \
        "#[fg=white,bold] Toggle: Ctrl+b,y \
| Move: Ctrl+b,Arrows \
| Resize: Ctrl+b,H/J/K/L "

    # --- MOUSE SUPPORT ---
    # Enables click-to-focus and drag-to-resize panes (helpful in Terminal.app).
    tmux set-option -g mouse on

    # --- SYNC TOGGLE SHORTCUT (Prefix + y) ---
    tmux bind-key -T prefix y \
        set-window-option -t "$SESSION" synchronize-panes \; \
        if-shell \
        "tmux show-window-options -t $SESSION -v \
synchronize-panes | grep on" \
        "set-window-option -t $SESSION status-bg red ; \
set-window-option -t $SESSION status-left \
'#[fg=white,bold] SYNC: ALL PANES ' ; \
set-option -t $SESSION pane-active-border-style \
'fg=red'" \
        "set-window-option -t $SESSION status-bg green ; \
set-window-option -t $SESSION status-left \
'#[fg=black,bold] MODE: SINGLE (Pane #P) ' ; \
set-option -t $SESSION pane-active-border-style \
'fg=green'"

    # --- PANE RESIZE SHORTCUTS (Prefix + Shift+hjkl) ---
    tmux bind-key -T prefix H resize-pane -L 5
    tmux bind-key -T prefix J resize-pane -D 2
    tmux bind-key -T prefix K resize-pane -U 2
    tmux bind-key -T prefix L resize-pane -R 5

    # --- INITIALIZE: START WITH SYNC ON ---
    tmux set-option -t "$SESSION" \
        pane-active-border-style 'fg=red'
    tmux set-window-option -t "$SESSION" \
        synchronize-panes on
    tmux set-window-option -t "$SESSION" \
        status-bg red
    tmux set-window-option -t "$SESSION" \
        status-left '#[fg=white,bold] SYNC: ALL PANES '
}

farm_tmux_reset_session() {
    local session="$1"
    tmux kill-session -t "$session" 2>/dev/null
}

farm_tmux_add_pane() {
    local session="$1"
    local cmd="$2"
    local title="$3"
    local init_width="${4:-}"
    local init_height="${5:-}"

    if tmux has-session -t "$session" 2>/dev/null; then
        tmux split-window -v -t "$session" "$cmd"
    else
        if [ -n "$init_width" ] && [ -n "$init_height" ]; then
            tmux new-session -d -x "$init_width" -y "$init_height" \
                -s "$session" "$cmd"
        else
            tmux new-session -d -s "$session" "$cmd"
        fi
    fi

    tmux select-pane -t "$session" -T " $title "
    tmux select-layout -t "$session" even-vertical
}

farm_tmux_print_cheatsheet() {
    clear
    farm_print_rule
    echo -e "${FARM_C_TITLE}        TMUX FARM CONTROL - CHEAT SHEET${FARM_C_RESET}"
    farm_print_rule
    echo ""
    echo -e "\e[1;33mSYNC MODE  (Prefix = Ctrl+b)\e[0m"
    echo -e "  \e[1;35mPrefix + y\e[0m   Toggle sync on/off"
    echo -e "  \e[1;31mRED bar\e[0m      Sync ON  - sends to ALL nodes"
    echo -e "  \e[1;32mGREEN bar\e[0m    Sync OFF - focused pane only"
    echo ""
    echo -e "\e[1;33mPANE CONTROL\e[0m"
    echo -e "  \e[1;35mPrefix + Arrows\e[0m  Move between panes"
    echo -e "  \e[1;35mPrefix + z\e[0m       Zoom/unzoom pane"
    echo -e "  \e[1;35mPrefix + H/J/K/L\e[0m Resize pane"
    echo -e "  \e[1;35mMouse drag\e[0m        Resize pane"
    echo -e "  \e[1;35mPrefix + q\e[0m       Show pane numbers"
    echo -e "  \e[1;35mPrefix + {\e[0m       Swap pane up"
    echo -e "  \e[1;35mPrefix + }\e[0m       Swap pane down"
    echo ""
    echo -e "\e[1;33mSCROLL & COPY\e[0m"
    echo -e "  \e[1;35mPrefix + [\e[0m       Enter scroll mode"
    echo -e "  \e[1;37mq\e[0m                Exit scroll mode"
    echo -e "  \e[1;35mPrefix + PgUp\e[0m    Scroll up one page"
    echo ""
    echo -e "\e[1;33mSESSION\e[0m"
    echo -e "  \e[1;35mPrefix + d\e[0m       Detach (nodes keep running)"
    echo -e "  \e[1;37mexit\e[0m             Close a single pane"
    echo -e "  \e[1;37mtmux ls\e[0m          List running sessions"
    echo ""

    if [ -n "$FARM_WINDOWS_EXCLUDED" ]; then
        echo -e "\e[1;33mWINDOWS CLIENTS (excluded from tmux)\e[0m"
        for node in $FARM_WINDOWS_EXCLUDED; do
            echo -e "  - $node"
        done
        echo ""
    fi

    farm_print_rule
    echo ""
}

farm_launch_terminal() {
    local TITLE="$1"
    local X_START="$2"
    local SESSION="$3"
    local SLEEP="${4:-1.5}"
    local WIN_W="${5:-}"
    local WIN_H="${6:-}"
    local debug_terminal="${FARM_DEBUG_TERMINAL:-0}"
    local osa_err

    # Ensure the tmux session exists before trying to attach from a new terminal.
    until tmux has-session -t "$SESSION" 2>/dev/null; do
        sleep 0.2
    done

    if [[ "$FARM_OS" == "mac" ]]; then
        # Prefer iTerm2 on macOS; fallback to Terminal.app when iTerm2 is missing.
        if osascript -e 'id of application "iTerm2"' >/dev/null 2>&1; then
            [ "$debug_terminal" = "1" ] && \
                echo "[farm_launch_terminal] mac path: iTerm2 new window"
            osascript \
                -e 'tell application "iTerm2"' \
                -e '  activate' \
                -e '  set newWindow to (create window with default profile)' \
                -e "  tell newWindow" \
                -e "    tell current session" \
                -e "      set name to \"${TITLE}\"" \
                -e "      write text \"tmux attach-session -t ${SESSION}\"" \
                -e "    end tell" \
                -e "  end tell" \
                -e 'end tell' >/dev/null 2>&1
        else
            # Open a dedicated Terminal window and run tmux there, so the
            # caller terminal stays free for the main script.
            [ "$debug_terminal" = "1" ] && \
                echo "[farm_launch_terminal] mac path: Terminal.app fallback chain (Cmd+N -> make new window -> do script)"
            osa_err=$(osascript \
                -e 'tell application "Terminal"' \
                -e '  activate' \
                -e '  try' \
                -e '    tell application "System Events" to keystroke "n" using {command down}' \
                -e '    delay 0.2' \
                -e '    do script "echo [farm_launch_terminal] branch: cmd+n/front-window" in selected tab of front window' \
                -e "    do script \"printf '\\\\e]1;${TITLE}\\\\a'; tmux attach-session -t ${SESSION}\" in selected tab of front window" \
                -e '  on error' \
                -e '    try' \
                -e '      set tmuxWindow to (make new window)' \
                -e '      do script "echo [farm_launch_terminal] branch: make-new-window" in selected tab of tmuxWindow' \
                -e "      do script \"printf '\\\\e]1;${TITLE}\\\\a'; tmux attach-session -t ${SESSION}\" in selected tab of tmuxWindow" \
                -e '    on error' \
                -e '      set tmuxTab to (do script "")' \
                -e '      do script "echo [farm_launch_terminal] branch: do-script-empty" in tmuxTab' \
                -e "      do script \"printf '\\\\e]1;${TITLE}\\\\a'; tmux attach-session -t ${SESSION}\" in tmuxTab" \
                -e '    end try' \
                -e '  end try' \
                -e 'end tell' 2>&1 >/dev/null)
            if [ "$debug_terminal" = "1" ] && [ -n "$osa_err" ]; then
                echo "[farm_launch_terminal] AppleScript stderr: $osa_err"
            fi
        fi
        sleep "$SLEEP"
        return 0
    fi

    # Linux behavior: prefer gnome-terminal when GUI is available.
    # Headless/no-display fallback: attach in current terminal.
    if [[ -z "${DISPLAY:-}" ]] || ! command -v gnome-terminal >/dev/null 2>&1; then
        echo "No GUI display/gnome-terminal detected. Attaching tmux in current terminal..."
        tmux attach-session -t "$SESSION"
        return 0
    fi

    gnome-terminal --title="$TITLE" \
        --geometry="110x100+${X_START}+0" \
        -- bash -c "tmux attach-session -t $SESSION" &

    sleep "$SLEEP"

    if command -v xdotool >/dev/null 2>&1; then
        WID=$(xdotool search --name "$TITLE" | head -n 1)
    else
        WID=""
    fi

    if [ ! -z "$WID" ]; then
        xdotool windowmove $WID $X_START 0
        if [ -n "$WIN_W" ] && [ -n "$WIN_H" ]; then
            # Widescreen mode: explicit size, no fullscreen.
            xdotool windowsize $WID $WIN_W $WIN_H
        else
            xdotool windowsize $WID 1080 1920
            if command -v wmctrl >/dev/null 2>&1; then
                wmctrl -ir $WID -b remove,maximized_vert,maximized_horz
                wmctrl -ir $WID -b add,fullscreen
            fi
        fi
        xdotool windowfocus $WID
    fi
}

