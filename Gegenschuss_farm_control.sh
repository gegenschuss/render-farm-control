#!/bin/bash
#  _____                         _
# |   __|___ ___ ___ ___ ___ ___| |_ _ _ ___ ___
# |  |  | -_| . | -_|   |_ -|  _|   | | |_ -|_ -|
# |_____|___|_  |___|_|_|___|___|_|_|___|___|___|
#           |___|
#
#SET CUSTOM SHORTCUT:
#gnome-terminal --window --profile="farm" -- bash -ic "farm; exit"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat << 'EOF'
Usage: ./Gegenschuss_farm_control.sh

Interactive farm launcher menu.

Tip:
  Use keyboard shortcuts shown in the menu to trigger actions quickly.
EOF
    exit 0
fi

cd "$(dirname "$0")"
source ./scripts/lib/config.sh
farm_require_bash4 "farm_control"

trap 'clear; tput cnorm; echo -e "\n  ${GREEN}Exiting Farm Control.${NC}"; exit 0' SIGINT SIGTERM
trap 'tput cnorm' ERR
trap 'handle_sigusr1' SIGUSR1

NC='\033[0m'
BOLD='\033[1m'
GREEN="$FARM_C_OK"
RED="$FARM_C_ERR"
YELLOW="$FARM_C_WARN"

DIM="$FARM_C_DIM"

function apply_random_menu_theme() {
    # Fixed palette: the single UI accent (#87d7ff) drives the shortcut
    # keys, section headers, selection bar and footer; 256-color and
    # classic ANSI fallbacks. Kept as a function so menu rebuilds stay
    # valid call sites.
    if [ "${FARM_UI_TC:-0}" -eq 1 ]; then
        CYAN='\033[38;2;135;215;255m'
        KEY_C="\033[1m${CYAN}"
        # Selection bar: accent background, near-black bold text.
        SEL_ON='\033[48;2;135;215;255m\033[38;2;20;20;20m\033[1m'
    elif [ "${FARM_UI_256:-0}" -eq 1 ]; then
        CYAN='\033[38;5;117m'
        KEY_C="\033[1m${CYAN}"
        SEL_ON='\033[48;5;117m\033[38;5;235m\033[1m'
    else
        CYAN='\033[94m'
        KEY_C="\033[1m${CYAN}"
        SEL_ON='\033[7m\033[1m'
    fi
}

apply_random_menu_theme

DEADLINECOMMAND="$FARM_DEADLINECOMMAND"
SCRIPTS="$FARM_SCRIPTS_DIR"
POWER_STATUS_ROW=0
LINE_WIDTH=59
PAIR_SPLIT=26   # column where the right side of a pair starts
CACHE_FILE="/tmp/farm_pm_state.cache"
PING_CACHE_FILE="/tmp/farm_ping_state.cache"
AUTOWAKE_ENABLED=0
AUTOWAKE_NEXT_EPOCH=0
AUTOWAKE_NEXT_SECONDS=-1
AUTOWAKE_NEXT_TEXT=""
AUTOWAKE_NEXT_SAMPLE_EPOCH=0

function set_terminal_title() {
    local timestamp=$(date +%s)
    local truncated_ts="${timestamp:4}"
    echo -ne "\033]0;$1 [${truncated_ts}]\007"
}

function exit_farm_control() {
    clear
    tput cnorm
    printf "\n  ${GREEN}Exiting Farm Control.${NC}\n"
    # Over SSH, close the interactive parent shell too ("double exit").
    if [[ -n "${SSH_CONNECTION:-}" && -n "${PPID:-}" ]]; then
        kill -HUP "$PPID" >/dev/null 2>&1 || true
    fi
    exit 0
}

function handle_sigusr1() {
    load_pm_state
    load_ping_state
    refresh_autowake_state
    build_menu

    tput civis

    for i in "${!MENU_ENTRIES[@]}"; do
        local type _s _p _c _a pairside
        IFS='|' read -r type _s _p _c _a pairside _ <<< "${MENU_ENTRIES[$i]}"
        # Skip right-side pair items: the left side redraws the full pair row.
        if [[ "$type" == "ITEM" && "$pairside" != "R" ]]; then
            local selected=0
            [[ "${SELECTABLE[$SELECTED_IDX]}" == "$i" ]] && selected=1
            render_item "$i" "$selected"
        fi
    done

    render_status_line

    tput cnorm
}

# ---------------------------------------------------------------------------
# HELPER: print a section header ("  ── LABEL ────…" — dim rule, accent
# label). Headers are stored as bare labels and colored at render time so
# they always match the current accent.
# ---------------------------------------------------------------------------
function render_header() {
    local label="$1" width=$LINE_WIDTH fill line=""
    local g="${FARM_G_RULE:-─}"
    if [[ -n "$label" ]]; then
        fill=$(( width - ${#label} - 6 ))
        (( fill < 0 )) && fill=0
        printf -v line "%${fill}s" ""
        printf '%b\n' "  ${DIM}${g}${g}${NC} ${BOLD}${CYAN}${label}${NC} ${DIM}${line// /$g}${NC}"
    else
        printf -v line "%$(( width - 2 ))s" ""
        printf '%b\n' "  ${DIM}${line// /$g}${NC}"
    fi
}

# ---------------------------------------------------------------------------
# HELPER: selected-row rendering (accent bar + pointer). The bar replaces
# the row's leading pad, so plain strings must start with >= 2 spaces.
# ---------------------------------------------------------------------------
function print_sel_full() {
    printf '%b%s%b' "$SEL_ON" " ${FARM_G_PTR}${1:2}" "$NC"
}

function print_sel_left() {   # $1=lplain $2=spaces $3=rcolored
    printf '%b%s%b%s%b' "$SEL_ON" " ${FARM_G_PTR}${1:2}" "$NC" "$2" "$3"
}

function print_sel_right() {  # $1=lcolored $2=spaces $3=rplain
    printf '%b%s%b%s%b' "$1" "$2" "$SEL_ON" "$3" "$NC"
}

# ---------------------------------------------------------------------------
# HELPER: build a justified line
# ---------------------------------------------------------------------------
# Shortcut key color: accent by default, warn for destructive actions,
# red for exit.
function key_color() {
    case "$1" in
        r|R|s|S|c|q|1|O) printf '%s' "${BOLD}${RED}" ;;
        *)           printf '%s' "$KEY_C" ;;
    esac
}

function make_line() {
    local shortcut="$1" label="${2,,}" hint="${3,,}" hintc="${4:-$DIM}"
    local prefix="   ${shortcut}  "
    local plain="${prefix}${label}"
    local pad=$(( LINE_WIDTH - ${#plain} - ${#hint} ))
    (( pad < 1 )) && pad=1
    local spaces
    printf -v spaces "%${pad}s" ""
    PLAIN_OUT="${prefix}${label}${spaces}${hint}"
    COLOR_OUT="   $(key_color "$shortcut")${shortcut}${NC}  ${label}${spaces}${hintc}${hint}${NC}"
}

# ---------------------------------------------------------------------------
# PAIR ITEMS  (two actions sharing one visual row)
# ---------------------------------------------------------------------------
declare -A PAIR_PARTNER   # entry_idx -> partner entry_idx

# Build a paired entry: two ITEMs that share one visual row.
# Fields 6-12 of the ITEM format carry pair metadata.
# Format: ITEM|shortcut|full_plain|full_colored|action|side|lplain|lcolored|spaces|rplain|rcolored|partner_s
function add_pair() {
    local s1="$1" label1="${2,,}" action1="$3" s2="$4" label2="${5,,}" action2="$6"

    local lplain="   ${s1}  ${label1}"
    local rplain="${s2}  ${label2}"

    local pad=$(( PAIR_SPLIT - ${#lplain} ))
    (( pad < 2 )) && pad=2
    local spaces; printf -v spaces "%${pad}s" ""

    local full_plain="${lplain}${spaces}${rplain}"
    local lcolored="   $(key_color "$s1")${s1}${NC}  ${label1}"
    local rcolored="$(key_color "$s2")${s2}${NC}  ${DIM}${label2}${NC}"
    local full_colored="${lcolored}${spaces}${rcolored}"

    local left_idx=${#MENU_ENTRIES[@]}
    MENU_ENTRIES+=( "ITEM|${s1}|${full_plain}|${full_colored}|${action1}|L|${lplain}|${lcolored}|${spaces}|${rplain}|${rcolored}|${s2}" )
    local right_idx=${#MENU_ENTRIES[@]}
    MENU_ENTRIES+=( "ITEM|${s2}|${full_plain}|${full_colored}|${action2}|R|${lplain}|${lcolored}|${spaces}|${rplain}|${rcolored}|${s1}" )

    PAIR_PARTNER[$left_idx]=$right_idx
    PAIR_PARTNER[$right_idx]=$left_idx
}

# Render the full visual row for a pair, given the left entry idx.
# left_sel=1 highlights left half; right_sel=1 highlights right half.
function _render_pair_row() {
    local left_idx=$1 left_sel=$2 right_sel=$3
    local row="${ENTRY_ROW[$left_idx]}"
    local _t _s full_plain full_colored _a _ps lplain lcolored spaces rplain rcolored
    IFS='|' read -r _t _s full_plain full_colored _a _ps lplain lcolored spaces rplain rcolored _ \
        <<< "${MENU_ENTRIES[$left_idx]}"

    tput sc
    tput cup "$row" 0
    printf "%-${#full_plain}s" " "
    tput cup "$row" 0

    if [[ "$left_sel" == "1" ]]; then
        print_sel_left "$lplain" "$spaces" "$rcolored"
    elif [[ "$right_sel" == "1" ]]; then
        print_sel_right "$lcolored" "$spaces" "$rplain"
    else
        printf '%b' "$full_colored"
    fi
    tput rc
}

# ---------------------------------------------------------------------------
# POWER MANAGEMENT STATE
# ---------------------------------------------------------------------------
declare -A PM_STATE

function load_pm_state() {
    local raw="DISABLED|DISABLED"
    [[ -f "$CACHE_FILE" ]] && raw=$(cat "$CACHE_FILE")
    local farm_raw ws_raw
    IFS='|' read -r farm_raw ws_raw <<< "$raw"
    [[ "$farm_raw" == "ENABLED" ]] \
        && PM_STATE[farm]=1 || PM_STATE[farm]=0
    [[ "$ws_raw" == "ENABLED" ]] \
        && PM_STATE[ws]=1   || PM_STATE[ws]=0
    PM_STATE[all]=$(( PM_STATE[farm] & PM_STATE[ws] ))
}

function refresh_pm_state_async() {
    : # render manager integration removed
}

function pm_status_str() {
    local key=$1
    [ "${PM_STATE[$key]}" == "1" ] \
        && printf "${GREEN}[ON] ${NC}" \
        || printf "${RED}[OFF]${NC}"
}

# ---------------------------------------------------------------------------
# PING STATE
# ---------------------------------------------------------------------------
PING_ONLINE=0
PING_TOTAL=${#NODES[@]}

function load_ping_state() {
    if [[ -f "$PING_CACHE_FILE" ]]; then
        PING_ONLINE=$(cat "$PING_CACHE_FILE")
    fi
}

function refresh_ping_state_sync() {
    local count=0
    for node in "${NODES[@]}"; do
        # Count nodes as online only when they are Linux/eligible.
        farm_get_node_os_status "$node" "ping"
        [ $? -eq 2 ] && (( count++ ))
    done
    PING_ONLINE="$count"
    echo "$count" > "$PING_CACHE_FILE"
}

function refresh_ping_state_async() {
    local _parent=$$
    (
        local node count=0
        local tmp_dir
        tmp_dir=$(mktemp -d)
        local -a _pids=()

        # Check all nodes in parallel.
        for node in "${NODES[@]}"; do
            (
                farm_get_node_os_status "$node" "ping"
                [ $? -eq 2 ] && echo 1 > "$tmp_dir/$node"
            ) &
            _pids+=($!)
        done
        for pid in "${_pids[@]}"; do wait "$pid" 2>/dev/null; done

        for node in "${NODES[@]}"; do
            [[ -f "$tmp_dir/$node" ]] && (( count++ ))
        done
        rm -rf "$tmp_dir"

        local old=""
        [[ -f "$PING_CACHE_FILE" ]] && old=$(cat "$PING_CACHE_FILE")
        echo "$count" > "$PING_CACHE_FILE"
        if [[ "$count" != "$old" ]]; then
            kill -USR1 $_parent 2>/dev/null
        fi
    ) &
}

function ping_status_str() {
    local total=${#NODES[@]}
    if (( PING_ONLINE == total )); then
        printf "Nodes: ${GREEN}${PING_ONLINE}/${total} online${NC}"
    elif (( PING_ONLINE == 0 )); then
        printf "Nodes: ${RED}${PING_ONLINE}/${total} online${NC}"
    else
        printf "Nodes: ${YELLOW}${PING_ONLINE}/${total} online${NC}"
    fi
}

# One dot per node: green filled = online (Linux), dim hollow = not.
function node_dots_str() {
    local total=${#NODES[@]} i out=""
    for (( i=0; i<total; i++ )); do
        if (( i < PING_ONLINE )); then
            out+="${GREEN}${FARM_G_DOT}${NC}"
        else
            out+="${DIM}${FARM_G_DOT_OFF}${NC}"
        fi
    done
    printf '%b' "$out"
}

function nodes_ratio_str() {
    local total=${#NODES[@]}
    if (( PING_ONLINE == total )); then
        printf "${GREEN}%s/%s${NC}" "$PING_ONLINE" "$total"
    elif (( PING_ONLINE == 0 )); then
        printf "${RED}%s/%s${NC}" "$PING_ONLINE" "$total"
    else
        printf "${YELLOW}%s/%s${NC}" "$PING_ONLINE" "$total"
    fi
}

function refresh_autowake_state() {
    AUTOWAKE_ENABLED=0
    AUTOWAKE_NEXT_EPOCH=0
    AUTOWAKE_NEXT_SECONDS=-1
    AUTOWAKE_NEXT_TEXT=""
    AUTOWAKE_NEXT_SAMPLE_EPOCH=0

    if timeout 5 bash "$SCRIPTS/deadline/autowake.sh" is-enabled >/dev/null 2>&1; then
        AUTOWAKE_ENABLED=1
    else
        return
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        return
    fi

    local next_raw next_epoch next_mono now_mono diff_mono mono_seconds
    next_mono=$(systemctl --user show farm-autowake.timer \
        -p NextElapseUSecMonotonic --value 2>/dev/null | sed -n '1p')
    if [[ -n "$next_mono" && "$next_mono" != "0" && "$next_mono" != "n/a" ]]; then
        AUTOWAKE_NEXT_TEXT=$(echo "$next_mono" | sed -E 's/([0-9])\.[0-9]+s/\1s/g; s/[[:space:]]+/ /g; s/^ //; s/ $//')
        if [[ "$next_mono" =~ ^[0-9]+$ ]] && [ "$next_mono" -gt 0 ]; then
            now_mono=$(awk '{printf "%.0f", $1 * 1000000}' /proc/uptime 2>/dev/null)
            if [[ "$now_mono" =~ ^[0-9]+$ ]]; then
                diff_mono=$(( (next_mono - now_mono) / 1000000 ))
                if [ "$diff_mono" -ge 0 ]; then
                    AUTOWAKE_NEXT_SECONDS="$diff_mono"
                    AUTOWAKE_NEXT_SAMPLE_EPOCH=$(date +%s)
                    return
                fi
            fi
        else
            mono_seconds=0
            if [[ "$next_mono" =~ ([0-9]+)h ]]; then
                mono_seconds=$(( mono_seconds + BASH_REMATCH[1] * 3600 ))
            fi
            if [[ "$next_mono" =~ ([0-9]+)min ]]; then
                mono_seconds=$(( mono_seconds + BASH_REMATCH[1] * 60 ))
            fi
            if [[ "$next_mono" =~ ([0-9]+)(\.[0-9]+)?s ]]; then
                mono_seconds=$(( mono_seconds + BASH_REMATCH[1] ))
            fi
            # Some systemd versions show monotonic as absolute since boot in words.
            # If so, subtract current uptime; otherwise treat parsed value as already-left.
            now_mono=$(awk '{printf "%.0f", $1}' /proc/uptime 2>/dev/null)
            if [[ "$now_mono" =~ ^[0-9]+$ ]] && [ "$mono_seconds" -ge "$now_mono" ]; then
                diff_mono=$(( mono_seconds - now_mono ))
            else
                diff_mono="$mono_seconds"
            fi
            if [ "$diff_mono" -ge 0 ]; then
                AUTOWAKE_NEXT_SECONDS="$diff_mono"
                AUTOWAKE_NEXT_SAMPLE_EPOCH=$(date +%s)
                return
            fi
        fi
    fi

    next_raw=$(systemctl --user show farm-autowake.timer \
        -p NextElapseUSecRealtime --value 2>/dev/null | sed -n '1p')
    if [[ -n "$next_raw" && "$next_raw" != "n/a" ]]; then
        next_epoch=$(date -d "$next_raw" +%s 2>/dev/null)
        if [[ "$next_epoch" =~ ^[0-9]+$ ]]; then
            AUTOWAKE_NEXT_EPOCH="$next_epoch"
            local now_epoch
            now_epoch=$(date +%s)
            AUTOWAKE_NEXT_SECONDS=$(( next_epoch - now_epoch ))
            AUTOWAKE_NEXT_SAMPLE_EPOCH="$now_epoch"
        fi
    fi
}

function autowake_next_str() {
    if [ "$AUTOWAKE_ENABLED" -ne 1 ]; then
        printf "${RED}off${NC}"
        return
    fi

    local diff h m s
    if [ "$AUTOWAKE_NEXT_SECONDS" -ge 0 ]; then
        local now elapsed
        now=$(date +%s)
        if [ "$AUTOWAKE_NEXT_SAMPLE_EPOCH" -gt 0 ]; then
            elapsed=$(( now - AUTOWAKE_NEXT_SAMPLE_EPOCH ))
            (( elapsed < 0 )) && elapsed=0
            diff=$(( AUTOWAKE_NEXT_SECONDS - elapsed ))
        else
            diff="$AUTOWAKE_NEXT_SECONDS"
        fi
    elif [ "$AUTOWAKE_NEXT_EPOCH" -gt 0 ]; then
        local now
        now=$(date +%s)
        diff=$(( AUTOWAKE_NEXT_EPOCH - now ))
    elif [ -n "$AUTOWAKE_NEXT_TEXT" ]; then
        printf "${CYAN}%s${NC}" "$AUTOWAKE_NEXT_TEXT"
        return
    else
        printf "${YELLOW}unknown${NC}"
        return
    fi

    if [ "$diff" -le 0 ]; then
        printf "${YELLOW}due now${NC}"
        return
    fi

    h=$(( diff / 3600 ))
    m=$(( (diff % 3600) / 60 ))
    s=$(( diff % 60 ))
    if [ "$h" -gt 0 ]; then
        printf "${CYAN}%dh%02dm${NC}" "$h" "$m"
    elif [ "$m" -gt 0 ]; then
        printf "${CYAN}%dm%02ds${NC}" "$m" "$s"
    else
        printf "${CYAN}%ds${NC}" "$s"
    fi
}

function render_status_line() {
    local cache_age=""
    if [ -f "$PING_CACHE_FILE" ]; then
        local mtime now
        mtime=$(stat -c %Y "$PING_CACHE_FILE" 2>/dev/null || stat -f %m "$PING_CACHE_FILE" 2>/dev/null)
        now=$(date +%s)
        if [[ "$mtime" =~ ^[0-9]+$ ]]; then
            cache_age=$(( now - mtime ))
        fi
    fi

    tput sc
    tput cup "$POWER_STATUS_ROW" 0
    tput el
    if [ "$AUTOWAKE_ENABLED" -eq 1 ]; then
        printf '%b' "   ${DIM}autowake${NC} ${GREEN}${FARM_G_DOT} on${NC} ${DIM}${FARM_G_SEP} next${NC} $(autowake_next_str)"
    else
        printf '%b' "   ${DIM}autowake ${FARM_G_DOT_OFF} off${NC}"
    fi
    printf '%b' "   ${DIM}nodes${NC} $(node_dots_str) $(nodes_ratio_str)"
    [ -n "$cache_age" ] && printf '%b' " ${DIM}(${cache_age}s)${NC}"
    tput rc
}

# ---------------------------------------------------------------------------
# BUILD MENU
# ---------------------------------------------------------------------------
MENU_ENTRIES=()
SELECTABLE=()
declare -A SHORTCUT_MAP
declare -A ENTRY_ROW

function build_menu() {
    MENU_ENTRIES=()
    SELECTABLE=()
    SHORTCUT_MAP=()
    PAIR_PARTNER=()

    # New accent per build so stored item colors, headers, selection bar
    # and footer always match.
    apply_random_menu_theme

    if [ "$AUTOWAKE_ENABLED" -eq 1 ]; then
        make_line "9" "Toggle AutoWake Timer" "${FARM_G_DOT} on " "$GREEN"
    else
        make_line "9" "Toggle AutoWake Timer" "${FARM_G_DOT_OFF} off" "$DIM"
    fi
    MENU_ENTRIES+=( "HEADER|autowake" )
    MENU_ENTRIES+=( "ITEM|9|${PLAIN_OUT}|${COLOR_OUT}|autowake_toggle" )

    MENU_ENTRIES+=( "HEADER|farm scripts" )
    make_line "x" "Status"        ; MENU_ENTRIES+=( "ITEM|x|${PLAIN_OUT}|${COLOR_OUT}|status" )
    make_line "w" "Wake"          ; MENU_ENTRIES+=( "ITEM|w|${PLAIN_OUT}|${COLOR_OUT}|wake" )
    add_pair "v" "NVTop"     "nvtop"                    "V" "+Workstation" "nvtop_local"
    add_pair "t" "Control"   "control"                  "T" "+Workstation" "control_local"
    add_pair "u" "Update"    "update"                   "U" "+Workstation" "update_local"
    add_pair "r" "Reboot"    "reboot"                   "R" "+Workstation" "reboot_local"
    add_pair "s" "Shutdown"  "shutdown"                 "S" "+Workstation" "shutdown_local"
    add_pair "j" "Submit"    "deadline_shutdown_submit" "J" "+Workstation" "deadline_shutdown_submit_local"

    MENU_ENTRIES+=( "HEADER|farm install" )
    make_line "1" "Houdini"    ; MENU_ENTRIES+=( "ITEM|1|${PLAIN_OUT}|${COLOR_OUT}|install_houdini" )
    make_line "2" "Houdini License" ; MENU_ENTRIES+=( "ITEM|2|${PLAIN_OUT}|${COLOR_OUT}|license_houdini" )

    MENU_ENTRIES+=( "HEADER|workstation scripts" )
    make_line "c" "Cache"                 ; MENU_ENTRIES+=( "ITEM|c|${PLAIN_OUT}|${COLOR_OUT}|cache" )
    make_line "p" "Selftest"                ; MENU_ENTRIES+=( "ITEM|p|${PLAIN_OUT}|${COLOR_OUT}|selftest" )

    MENU_ENTRIES+=( "HEADER|start applications" )
    make_line "h" "Houdini"                    ; MENU_ENTRIES+=( "ITEM|h|${PLAIN_OUT}|${COLOR_OUT}|houdini" )
    add_pair "n" "Nuke"             "nuke"             "N" "+Update"       "nuke_update"
    make_line "e" "SynthEyes"                  ; MENU_ENTRIES+=( "ITEM|e|${PLAIN_OUT}|${COLOR_OUT}|syntheyes" )
    add_pair "m" "Mocha"            "mocha"            "M" "+Update"       "mocha_import"
    add_pair "b" "Blender"          "blender"          "B" "+Update"       "blender_update"
    add_pair "d" "Davinci"          "davinci"          "D" "+Update"       "resolve_update"
    add_pair "o" "Deadline Monitor" "deadline_monitor" "O" "+Farm Install" "install_deadline"

    MENU_ENTRIES+=( "HEADER|" )
    make_line "?" "Help" ""
    MENU_ENTRIES+=( "ITEM|?|${PLAIN_OUT}|${COLOR_OUT}|help" )
    make_line "q" "Exit" ""
    MENU_ENTRIES+=( "ITEM|q|${PLAIN_OUT}|${COLOR_OUT}|quit" )

    SELECTABLE=()
    for i in "${!MENU_ENTRIES[@]}"; do
        local type shortcut
        IFS='|' read -r type shortcut _ <<< "${MENU_ENTRIES[$i]}"
        if [[ "$type" == "ITEM" ]]; then
            SELECTABLE+=("$i")
            SHORTCUT_MAP["$shortcut"]=$(( ${#SELECTABLE[@]} - 1 ))
        fi
    done
}

# ---------------------------------------------------------------------------
# STATUS INJECTION
# ---------------------------------------------------------------------------
function get_cursor_row() {
    local oldstty response row
    oldstty=$(stty -g)
    stty raw -echo min 0 time 5
    printf "\033[6n" > /dev/tty
    IFS= read -r -d R response < /dev/tty || true
    stty "$oldstty"
    if [[ "$response" =~ \[([0-9]+)\;([0-9]+)$ ]]; then
        row="${BASH_REMATCH[1]}"
    else
        row=1
    fi
    (( row < 1 )) && row=1
    echo $(( row - 1 ))
}

function minimize_after() {
    if [[ "$FARM_OS" == "linux" && -n "$WINDOW_ID" ]]; then
        ( sleep "${1:-5}" && xdotool windowminimize "$WINDOW_ID" ) &
    fi
}

# ---------------------------------------------------------------------------
# RENDER SINGLE ITEM
# ---------------------------------------------------------------------------
function render_item() {
    local entry_idx=$1 selected=$2
    local _t shortcut plain colored _a pairside _lp _lc _sp _rp _rc partner_s
    IFS='|' read -r _t shortcut plain colored _a pairside _lp _lc _sp _rp _rc partner_s \
        <<< "${MENU_ENTRIES[$entry_idx]}"

    if [[ -n "$pairside" ]]; then
        # Resolve which side of the pair is currently the global selection.
        local partner_idx="${PAIR_PARTNER[$entry_idx]:-}"
        local partner_is_cur=0
        [[ -n "$partner_idx" && "${SELECTABLE[$SELECTED_IDX]}" == "$partner_idx" ]] \
            && partner_is_cur=1

        local left_idx right_sel=0 left_sel=0
        if [[ "$pairside" == "L" ]]; then
            left_idx=$entry_idx
            [[ "$selected"         == "1" ]] && left_sel=1
            [[ "$partner_is_cur"   == "1" ]] && right_sel=1
        else
            left_idx="$partner_idx"
            [[ "$selected"         == "1" ]] && right_sel=1
            [[ "$partner_is_cur"   == "1" ]] && left_sel=1
        fi
        _render_pair_row "$left_idx" "$left_sel" "$right_sel"
        return
    fi

    # Normal (non-pair) item
    local row="${ENTRY_ROW[$entry_idx]}"
    tput sc
    tput cup "$row" 0
    printf "%-${#plain}s" " "
    tput cup "$row" 0
    if [[ "$selected" == "1" ]]; then
        print_sel_full "$plain"
    else
        printf '%b' "$colored"
    fi
    tput rc
}

# ---------------------------------------------------------------------------
# FULL RENDER
# ---------------------------------------------------------------------------
function render_menu() {
    clear
    tput civis
    "$SCRIPTS/lib/header.sh"

    local current_row
    current_row=$(get_cursor_row)

    for i in "${!MENU_ENTRIES[@]}"; do
        local type label plain colored _a pairside
        IFS='|' read -r type label plain colored _a pairside _ \
            <<< "${MENU_ENTRIES[$i]}"

        if [[ "$type" == "HEADER" && "$i" != "0" ]]; then
            printf "\n"
            (( current_row++ ))
        fi

        ENTRY_ROW[$i]=$current_row

        if [[ "$type" == "HEADER" ]]; then
            render_header "$label"
            (( current_row++ ))
            if [[ "$i" == "0" ]]; then
                POWER_STATUS_ROW=$current_row
                printf "\n"
                (( current_row++ ))
            fi
        elif [[ "$pairside" == "R" ]]; then
            # Right-side pair item shares its row with the left item (already printed).
            ENTRY_ROW[$i]=$(( current_row - 1 ))
        else
            # Normal item or left-side of a pair.
            local cur="${SELECTABLE[$SELECTED_IDX]}"
            if [[ "$pairside" == "L" ]]; then
                local right_idx="${PAIR_PARTNER[$i]:-}"
                if [[ "$cur" == "$i" ]]; then
                    # Left is selected
                    local _t _s _fp _fc _a2 _ps lplain lcolored spaces rplain rcolored
                    IFS='|' read -r _t _s _fp _fc _a2 _ps lplain lcolored spaces rplain rcolored _ \
                        <<< "${MENU_ENTRIES[$i]}"
                    print_sel_left "$lplain" "$spaces" "$rcolored"; printf '\n'
                elif [[ -n "$right_idx" && "$cur" == "$right_idx" ]]; then
                    # Right is selected
                    local _t _s _fp _fc _a2 _ps lplain lcolored spaces rplain rcolored
                    IFS='|' read -r _t _s _fp _fc _a2 _ps lplain lcolored spaces rplain rcolored _ \
                        <<< "${MENU_ENTRIES[$i]}"
                    print_sel_right "$lcolored" "$spaces" "$rplain"; printf '\n'
                else
                    printf '%b\n' "$colored"
                fi
            else
                if [[ "$cur" == "$i" ]]; then
                    print_sel_full "$plain"; printf '\n'
                else
                    printf '%b\n' "$colored"
                fi
            fi
            (( current_row++ ))
        fi
    done

    printf "\n"
    printf '%b\n' "  ${DIM}${FARM_G_PTR} enter run ${FARM_G_SEP} ↑↓ move ${FARM_G_SEP} key jump ${FARM_G_SEP} q quit${NC}"

    render_status_line
}

# ---------------------------------------------------------------------------
# POWER TOGGLE ACTIONS
# ---------------------------------------------------------------------------
function pm_toggle() {
    local target=$1
    local script_on script_off key
    case "$target" in
        farm) script_on="on";             script_off="off";             key="farm" ;;
        ws)   script_on="workstation_on"; script_off="workstation_off"; key="ws" ;;
        all)  script_on="all_on";         script_off="all_off";         key="all" ;;
    esac

    local new_state
    if [ "$target" == "all" ]; then
        new_state=$(( 1 - PM_STATE[all] ))
        PM_STATE[farm]=$new_state
        PM_STATE[ws]=$new_state
        PM_STATE[all]=$new_state
    else
        new_state=$(( 1 - PM_STATE[$key] ))
        PM_STATE[$key]=$new_state
        PM_STATE[all]=$(( PM_STATE[farm] & PM_STATE[ws] ))
    fi

    local script
    [ "$new_state" == "1" ] \
        && script="$FARM_BASE_DIR/deadline/power_${script_on}.py" \
        || script="$FARM_BASE_DIR/deadline/power_${script_off}.py"
    "$DEADLINECOMMAND" ExecuteScriptNoGui "$script" \
        > /dev/null 2>&1

    refresh_pm_state_async
}

# ---------------------------------------------------------------------------
# WINDOW
# ---------------------------------------------------------------------------
UNIQUE_TITLE="FarmControl_INIT_$$"
if [[ "$FARM_OS" == "linux" ]]; then
    echo -ne "\033]0;${UNIQUE_TITLE}\007"
    sleep 0.1

    WINDOW_ID=$(xdotool search --name "$UNIQUE_TITLE" \
        2>/dev/null | head -n 1)
    [ -z "$WINDOW_ID" ] && \
        WINDOW_ID=$(xdotool getactivewindow 2>/dev/null)
else
    WINDOW_ID=""
fi

APP_WINDOW_SIZE='788 400'
MENU_WINDOW_SIZE='608 965'
AUTO_REFRESH_SECONDS=10
PING_REFRESH_SECONDS=30

function set_window_size() {
    local size="$1"
    if [[ "$FARM_OS" == "linux" && -n "$WINDOW_ID" ]]; then
        xdotool windowsize "$WINDOW_ID" $size
    fi
}

set_terminal_title "Farm Control"

# ---------------------------------------------------------------------------
# ACTIONS
# ---------------------------------------------------------------------------
function deadline_power() {
    local state=$1
    local script="$FARM_BASE_DIR/deadline/power_${state}.py"
    [ ! -f "$script" ] && \
        printf "  ${RED}Script not found: $script${NC}\n" && \
        return 1
    "$DEADLINECOMMAND" ExecuteScriptNoGui "$script" \
        > /dev/null 2>&1
}

function confirm_danger() {
    tput cnorm
    echo ""
    farm_print_danger_box "$1"
    echo ""
    read -n 1 -r -p \
        "$(printf "  ${RED}are you sure? [y/N] (q=cancel): ${NC}")" \
        confirm
    tput civis
    if [[ "$confirm" == "q" || "$confirm" == "Q" ]]; then
        printf "\n  ${YELLOW}Action cancelled.${NC}\n"
        return 1
    fi
    [[ "$confirm" =~ ^[Yy]$ ]] && printf "\n" && return 0
    printf "\n  ${YELLOW}Action cancelled.${NC}\n"
    return 1
}

# Returns 0 = show "press any key", 1 = instant return to menu
function run_action() {
    local action=$1
    case "$action" in
        autowake_toggle)
            set_terminal_title "Farm: Toggle AutoWake"
            if bash "$SCRIPTS/deadline/autowake.sh" is-enabled >/dev/null 2>&1; then
                bash "$SCRIPTS/deadline/autowake.sh" disable >/dev/null 2>&1
                bash "$SCRIPTS/deadline/autowake.sh" uninstall >/dev/null 2>&1
            else
                bash "$SCRIPTS/deadline/autowake.sh" install >/dev/null 2>&1
                bash "$SCRIPTS/deadline/autowake.sh" enable >/dev/null 2>&1
                bash "$SCRIPTS/deadline/autowake.sh" run-now >/dev/null 2>&1
            fi
            refresh_autowake_state
            build_menu
            return 1 ;;
        wake)
            set_terminal_title "Farm: Wake"
            printf "\n  ${GREEN}Waking up Farm...${NC}\n"
            $SCRIPTS/core/wake.sh ;;
        status)
            set_terminal_title "Farm: Status"
            printf "\n  ${CYAN}Checking Farm Status...${NC}\n"
            $SCRIPTS/core/status.sh ;;
        nvtop)
            set_terminal_title "Farm: NVTop"
            printf "\n  ${CYAN}Starting NVTop...${NC}\n"
            $SCRIPTS/core/node_session.sh nvtop
            return 1 ;;
        nvtop_local)
            set_terminal_title "Farm: NVTop + Workstation"
            printf "\n  ${CYAN}Starting NVTop + Workstation...${NC}\n"
            $SCRIPTS/core/node_session.sh nvtop --local
            return 1 ;;
        control)
            set_terminal_title "Farm: Control"
            printf "\n  ${CYAN}Opening Control...${NC}\n"
            $SCRIPTS/core/node_session.sh control
            return 1 ;;
        control_local)
            set_terminal_title "Farm: Control + Workstation"
            printf "\n  ${CYAN}Opening Control + Workstation...${NC}\n"
            $SCRIPTS/core/node_session.sh control --local
            return 1 ;;
        help)
            set_terminal_title "Farm: Help"
            printf "\n  ${CYAN}Opening Farm Help...${NC}\n"
            $SCRIPTS/lib/help.sh ;;
        update)
            set_terminal_title "Farm: Update"
            $SCRIPTS/core/update.sh ;;
        update_local)
            set_terminal_title "Farm: Update + Workstation"
            $SCRIPTS/core/update.sh --local ;;
        reboot)
            set_terminal_title "Farm: Reboot"
            $SCRIPTS/core/reboot.sh ;;
        reboot_local)
            set_terminal_title "Farm: Reboot + Workstation"
            $SCRIPTS/core/reboot.sh --local ;;
        shutdown)
            set_terminal_title "Farm: Shutdown"
            $SCRIPTS/core/shutdown.sh ;;
        shutdown_local)
            set_terminal_title "Farm: Shutdown + Workstation"
            $SCRIPTS/core/shutdown.sh --local ;;
        deadline_shutdown_submit)
            set_terminal_title "Farm: Submit Deadline Shutdown"
            $SCRIPTS/deadline/submit_shutdown.sh ;;
        deadline_shutdown_submit_local)
            set_terminal_title "Farm: Submit Deadline Shutdown + Workstation"
            $SCRIPTS/deadline/submit_shutdown.sh --with-workstation ;;
        install_houdini)
            confirm_danger "INSTALL HOUDINI ON FARM" && \
            $SCRIPTS/tools/install_app.sh houdini ;;
        install_deadline)
            confirm_danger "INSTALL DEADLINE ON FARM" && \
            $SCRIPTS/tools/install_app.sh deadline ;;
        blender_update)
            set_terminal_title "Farm: Blender Update"
            $SCRIPTS/tools/update_blender.sh ;;
        resolve_update)
            set_terminal_title "Farm: Resolve Update"
            $SCRIPTS/tools/update_resolve.sh ;;
        nuke_update)
            set_terminal_title "Farm: Nuke Update"
            $SCRIPTS/tools/update_nuke.sh ;;
        mocha_import)
            set_terminal_title "Farm: Mocha Import"
            $SCRIPTS/tools/import_mocha.sh ;;
        license_houdini)
            set_terminal_title "Farm: Houdini License"
            $SCRIPTS/tools/license_houdini.sh ;;
        cache)
            confirm_danger "DELETE ${FARM_LOCAL_NAME} CACHE" && \
            farm_sudo_auth && \
            sudo $SCRIPTS/tools/delcache.sh ;;
        selftest)
            set_terminal_title "Farm: Selftest"
            printf "\n  ${CYAN}Running farm deep selftest...${NC}\n"
            $SCRIPTS/tools/selftest.sh ;;
        houdini)
            set_terminal_title "Houdini"
            clear
            set_window_size "$APP_WINDOW_SIZE"
            minimize_after 5
            $SCRIPTS/tools/launch_houdini.sh ;;
        nuke)
            set_terminal_title "Nuke"
            clear
            set_window_size "$APP_WINDOW_SIZE"
            minimize_after 5
            $SCRIPTS/tools/launch_nuke.sh ;;
        syntheyes)
            set_terminal_title "SynthEyes"
            clear
            set_window_size "$APP_WINDOW_SIZE"
            minimize_after 5
            /opt/SynthEyes/SynthEyes.sh ;;
        mocha)
            set_terminal_title "Mocha"
            clear
            set_window_size "$APP_WINDOW_SIZE"
            minimize_after 5
            # Newest installed Mocha version (imports install in parallel).
            local mocha_dir mocha_bin
            mocha_dir=$(ls -1d /opt/BorisFX/MochaPro* 2>/dev/null | sort -V | tail -n 1)
            mocha_bin=$(find "$mocha_dir" -maxdepth 2 -path '*/bin/mochapro*' -type f 2>/dev/null | head -n 1)
            "$mocha_bin" --verbose ;;
        blender)
            set_terminal_title "Blender"
            clear
            set_window_size "$APP_WINDOW_SIZE"
            minimize_after 5
            /opt/blender/blender --debug-python ;;
        davinci)
            set_terminal_title "Davinci"
            clear
            set_window_size "$APP_WINDOW_SIZE"
            minimize_after 5
            /opt/resolve/bin/resolve ;;
        deadline_monitor)
            set_terminal_title "Deadline Monitor"
            clear
            set_window_size "$APP_WINDOW_SIZE"
            minimize_after 5
            "$(dirname "$DEADLINECOMMAND")/deadlinemonitor" ;;
        quit)
            exit_farm_control ;;
    esac
    return 0
}

function execute_selected() {
    local action
    IFS='|' read -r _ _ _ _ action _ _ _ _ _ _ _ \
        <<< "${MENU_ENTRIES[${SELECTABLE[$SELECTED_IDX]}]}"

    # Block SIGUSR1 while external commands run and during the prompt,
    # to prevent handle_sigusr1 from injecting tput sequences into output.
    trap '' SIGUSR1

    tput cnorm
    run_action "$action"
    local ret=$?

    # Normalize terminal state after external commands (tmux/apps/scripts)
    # so the menu redraw is always clean.
    stty sane 2>/dev/null
    tput sgr0
    tput cnorm

    if [ $ret -eq 0 ]; then
        refresh_ping_state_async   # runs while user reads output / presses key
        farm_prompt_rule
        read -n 1 -s -r -p "  Press any key to return to the menu..."
        set_window_size "$MENU_WINDOW_SIZE"
        load_pm_state
        load_ping_state
        build_menu
        refresh_pm_state_async
    fi

    # Re-arm SIGUSR1 before redrawing the menu (rows are valid after render_menu).
    trap 'handle_sigusr1' SIGUSR1

    render_menu
    tput cnorm
}

# ---------------------------------------------------------------------------
# INIT + MAIN LOOP
# ---------------------------------------------------------------------------
load_pm_state
load_ping_state
refresh_autowake_state
build_menu

# SELECT DEFAULT MENU ITEM
SELECTED_IDX="${SHORTCUT_MAP[x]}"

refresh_pm_state_async
refresh_ping_state_async

tput civis
render_menu
tput cnorm

LAST_AUTO_REFRESH_EPOCH=$(date +%s)
LAST_PING_REFRESH_EPOCH=$(date +%s)

while true; do
    key=""
    IFS= read -rsn1 -t 1 key
    ret=$?
    now_epoch=$(date +%s)

    if (( now_epoch - LAST_PING_REFRESH_EPOCH >= PING_REFRESH_SECONDS )); then
        refresh_ping_state_async
        LAST_PING_REFRESH_EPOCH=$now_epoch
    fi

    if (( now_epoch - LAST_AUTO_REFRESH_EPOCH >= AUTO_REFRESH_SECONDS )); then
        load_ping_state
        refresh_autowake_state
        render_status_line
        LAST_AUTO_REFRESH_EPOCH=$now_epoch
    fi

    if (( ret > 128 )); then
        render_status_line
        continue
    fi

    if [[ "$key" == $'\x1b' ]]; then
        read -rsn2 -t 0.1 key2
        case "$key2" in
            '[A')
                if (( SELECTED_IDX > 0 )); then
                    old="${SELECTABLE[$SELECTED_IDX]}"
                    (( SELECTED_IDX-- ))
                    # Skip right-side pair items — reachable only via ←
                    _ps6=""
                    IFS='|' read -r _ _ _ _ _ _ps6 _ \
                        <<< "${MENU_ENTRIES[${SELECTABLE[$SELECTED_IDX]}]}"
                    if [[ "$_ps6" == "R" ]] && (( SELECTED_IDX > 0 )); then
                        (( SELECTED_IDX-- ))
                    fi
                    new="${SELECTABLE[$SELECTED_IDX]}"
                    render_item "$old" 0
                    render_item "$new" 1
                fi ;;
            '[B')
                if (( SELECTED_IDX < ${#SELECTABLE[@]} - 1 )); then
                    old="${SELECTABLE[$SELECTED_IDX]}"
                    (( SELECTED_IDX++ ))
                    # Skip right-side pair items — reachable only via ←
                    _ps6=""
                    IFS='|' read -r _ _ _ _ _ _ps6 _ \
                        <<< "${MENU_ENTRIES[${SELECTABLE[$SELECTED_IDX]}]}"
                    if [[ "$_ps6" == "R" ]] && \
                       (( SELECTED_IDX < ${#SELECTABLE[@]} - 1 )); then
                        (( SELECTED_IDX++ ))
                    fi
                    new="${SELECTABLE[$SELECTED_IDX]}"
                    render_item "$old" 0
                    render_item "$new" 1
                fi ;;
            '[C'|'[D')
                # ←→ : toggle to the partner of the current pair item
                _cur_e="${SELECTABLE[$SELECTED_IDX]}"
                _t="" _s="" _p="" _c="" _a="" _ps="" _lp="" _lc="" _sp="" _rp="" _rc="" _partner_s=""
                IFS='|' read -r _t _s _p _c _a _ps _lp _lc _sp _rp _rc _partner_s \
                    <<< "${MENU_ENTRIES[$_cur_e]}"
                if [[ -n "$_ps" && -n "${SHORTCUT_MAP[$_partner_s]+x}" ]]; then
                    old="${SELECTABLE[$SELECTED_IDX]}"
                    SELECTED_IDX="${SHORTCUT_MAP[$_partner_s]}"
                    new="${SELECTABLE[$SELECTED_IDX]}"
                    render_item "$old" 0
                    render_item "$new" 1
                fi ;;
        esac

    elif [[ "$key" == "" ]]; then
        execute_selected

    elif [[ -n "${SHORTCUT_MAP[$key]+x}" ]]; then
        old="${SELECTABLE[$SELECTED_IDX]}"
        SELECTED_IDX="${SHORTCUT_MAP[$key]}"
        new="${SELECTABLE[$SELECTED_IDX]}"
        render_item "$old" 0
        render_item "$new" 1
        execute_selected

    elif [[ "$key" == "q" ]]; then
        exit_farm_control
    fi
done