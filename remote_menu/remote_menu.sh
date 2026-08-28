#!/bin/bash
#  _____                         _
# |   __|___ ___ ___ ___ ___ ___| |_ _ _ ___ ___
# |  |  | -_| . | -_|   |_ -|  _|   | | |_ -|_ -|
# |_____|___|_  |___|_|_|___|___|_|_|___|___|___|
#           |___|
#

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat << 'EOF'
Usage: ./remote_menu.sh

Interactive launcher for:
  - core/ping.sh
  - core/wake.sh
  - core/mount.sh
  - core/delcache.sh
  - core/unmount.sh
  - core/shutdown.sh

Tips:
  - Use arrow keys to navigate
  - Press Enter or shortcut key to run
EOF
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

HAS_LOGO=0
if [ -f "$SCRIPT_DIR/lib/logo.sh" ]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/logo.sh"
    HAS_LOGO=1
fi

# Load secrets (workstation SSH host, farm script paths).
if [ -f "$SCRIPT_DIR/config/secrets.sh" ]; then
    source "$SCRIPT_DIR/config/secrets.sh"
fi

# Shared palette + platform helpers: black & white, one accent
# (#87d7ff), red/green only for failed/good status.
source "$SCRIPT_DIR/lib/ui.sh"

NC="$C_RESET"
BOLD="$C_BOLD"
GREEN="$C_OK"
RED="$C_FAIL"
CYAN="$C_ACCENT"
YELLOW="$C_BOLD"          # warnings render bold, not colored
DIM="$C_DIM"
KEY_C="${C_BOLD}${C_ACCENT}"
SEL_ON="$UI_SEL_ON"

# Core scripts skip their own exit prompt; the menu prompts instead.
export REMOTE_MENU_ACTIVE=1
PTR='❯'
SEP='·'

LINE_WIDTH=58
MENU_ENTRIES=()
SELECTABLE=()
ENTRY_ROW=()
SELECTED_IDX=0

cleanup() {
    stty sane 2>/dev/null
    tput cnorm
}
trap cleanup EXIT

quit_menu() {
    clear
    printf "\n  ${GREEN}Exiting Remote Menu.${NC}\n"
    exit 0
}
trap quit_menu SIGINT SIGTERM

IN_MENU=0
handle_resize() {
    (( IN_MENU )) && render_menu
}
trap handle_resize SIGWINCH

# Run a child command with Ctrl-C interrupting only the child, not the menu.
run_child() {
    local ret
    trap ':' SIGINT
    "$@"
    ret=$?
    trap quit_menu SIGINT
    return $ret
}

confirm_danger() {
    local action_label="$1"
    # Red-bordered warning box (bash 3.2: rule built with a while loop).
    local width=$LINE_WIDTH inner line="" pad="" i=0
    inner=$(( width - 2 ))
    while [ "$i" -lt "$inner" ]; do line="${line}─"; i=$((i+1)); done
    i=$(( inner - ${#action_label} - 5 ))
    [ "$i" -lt 0 ] && i=0
    printf -v pad "%${i}s" ""
    tput cnorm
    printf "\n  ${RED}╭%s╮${NC}\n" "$line"
    printf "  ${RED}│${NC} ${YELLOW}⚠${NC}  ${RED}%s${NC}%s ${RED}│${NC}\n" "$action_label" "$pad"
    printf "  ${RED}╰%s╯${NC}\n\n" "$line"
    read -n 1 -r -p "$(printf "  ${RED}are you sure? [y/N] (q=cancel): ${NC}")" confirm
    printf "\n"
    # No civis here: a confirmed child script runs next and would
    # inherit a hidden cursor; the menu re-hides it on redraw.
    [[ "$confirm" =~ ^[Yy]$ ]]
}

# Section header: "  ── LABEL ────…" — dim rule, accent label. Headers
# are stored as bare labels and colored at render time.
# Plain bash 3.2 constructs only (macOS default bash).
render_header() {
    local label="$1" width=$LINE_WIDTH line="" fill=0 i=0
    if [ -n "$label" ]; then
        fill=$(( width - ${#label} - 6 ))
        [ "$fill" -lt 0 ] && fill=0
    else
        fill=$(( width - 2 ))
    fi
    while [ "$i" -lt "$fill" ]; do line="${line}─"; i=$((i+1)); done
    if [ -n "$label" ]; then
        printf '%b\n' "  ${DIM}──${NC} ${BOLD}${C_H2}${label}${NC} ${DIM}${line}${NC}"
    else
        printf '%b\n' "  ${DIM}${line}${NC}"
    fi
}

# Shortcut key color: accent by default, red for destructive actions
# and exit.
key_color() {
    case "$1" in
        x|u|q) printf '%s' "${BOLD}${RED}" ;;
        *)     printf '%s' "$KEY_C" ;;
    esac
}

make_line() {
    local shortcut="$1" label hint
    # Menu text displays all-lowercase (tr, not ${var,,}: bash 3.2).
    label=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
    hint=$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')
    local prefix="   ${shortcut}  "
    local plain="${prefix}${label}"
    local pad=$(( LINE_WIDTH - ${#plain} - ${#hint} ))
    (( pad < 1 )) && pad=1
    local spaces
    printf -v spaces "%${pad}s" ""
    PLAIN_OUT="${prefix}${label}${spaces}${hint}"
    COLOR_OUT="   $(key_color "$shortcut")${shortcut}${NC}  ${label}${DIM}${spaces}${hint}${NC}"
}

# Selected row: accent bar + pointer, replacing the row's leading pad.
print_sel_full() {
    printf '%b%s%b' "$SEL_ON" " ${PTR}${1:2}" "$NC"
}

build_menu() {
    MENU_ENTRIES=()
    SELECTABLE=()

    # Mounted-share indicator for the SHARES header.
    local shares_label="shares" _s _mounted=0 _total=0
    for _s in "${DEADLINE_SHARE:-}" "${NAS_STUDIO_SHARE:-}" "${NAS_BUERO_SHARE:-}" \
              "${WORKSTATION_HOUDINI_SHARE:-}" "${WORKSTATION_NUKE_SHARE:-}"; do
        [ -n "$_s" ] || continue
        _total=$(( _total + 1 ))
        share_mounted "$_s" && _mounted=$(( _mounted + 1 ))
    done
    if [ "$_total" -gt 0 ]; then
        shares_label="shares ${SEP} ${_mounted}/${_total} mounted"
    fi

    MENU_ENTRIES+=( "HEADER|status" )
    make_line "s" "Ping"     "Ping remote nodes"
    MENU_ENTRIES+=( "ITEM|s|${PLAIN_OUT}|${COLOR_OUT}|status" )
    make_line "f" "Login"    "SSH to workstation farm menu"
    MENU_ENTRIES+=( "ITEM|f|${PLAIN_OUT}|${COLOR_OUT}|farm" )
    MENU_ENTRIES+=( "HEADER|start" )
    make_line "w" "Start"    "Wake + mount + connect"
    MENU_ENTRIES+=( "ITEM|w|${PLAIN_OUT}|${COLOR_OUT}|wake" )
    MENU_ENTRIES+=( "HEADER|${shares_label}" )
    make_line "m" "Mount"     "Mount shares (Tailscale)"
    MENU_ENTRIES+=( "ITEM|m|${PLAIN_OUT}|${COLOR_OUT}|mount" )
    make_line "l" "Mount LAN" "Mount shares via local network"
    MENU_ENTRIES+=( "ITEM|l|${PLAIN_OUT}|${COLOR_OUT}|mount_local" )
    make_line "u" "Unmount"   "Unmount all remote shares"
    MENU_ENTRIES+=( "ITEM|u|${PLAIN_OUT}|${COLOR_OUT}|unmount" )
    MENU_ENTRIES+=( "HEADER|maintenance" )
    make_line "c" "Cache"    "Purge local caches"
    MENU_ENTRIES+=( "ITEM|c|${PLAIN_OUT}|${COLOR_OUT}|delcache" )
    MENU_ENTRIES+=( "HEADER|shutdown" )
    make_line "x" "Shutdown" "Shutdown remote linux workstation & nodes"
    MENU_ENTRIES+=( "ITEM|x|${PLAIN_OUT}|${COLOR_OUT}|shutdown_remote" )
    MENU_ENTRIES+=( "HEADER|" )
    make_line "q" "Exit" ""
    MENU_ENTRIES+=( "ITEM|q|${PLAIN_OUT}|${COLOR_OUT}|quit" )

    local i type
    for i in "${!MENU_ENTRIES[@]}"; do
        IFS='|' read -r type _ <<< "${MENU_ENTRIES[$i]}"
        if [[ "$type" == "ITEM" ]]; then
            SELECTABLE+=( "$i" )
        fi
    done
}

entry_index_for_shortcut() {
    local key="$1"
    local i entry_idx type shortcut
    for i in "${!SELECTABLE[@]}"; do
        entry_idx="${SELECTABLE[$i]}"
        IFS='|' read -r type shortcut _ <<< "${MENU_ENTRIES[$entry_idx]}"
        if [[ "$type" == "ITEM" && "$shortcut" == "$key" ]]; then
            echo "$i"
            return 0
        fi
    done
    return 1
}

get_cursor_row() {
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

render_item() {
    local entry_idx=$1 selected=$2 row plain colored
    row="${ENTRY_ROW[$entry_idx]}"
    IFS='|' read -r _ _ plain colored _ <<< "${MENU_ENTRIES[$entry_idx]}"

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

render_menu() {
    clear
    tput civis
    if [ "$HAS_LOGO" -eq 1 ] && declare -F print_logo >/dev/null 2>&1; then
        if declare -F pick_gradient >/dev/null 2>&1; then
            print_logo "$(pick_gradient)"
        else
            print_logo "$CYAN"
        fi
    fi

    local current_row i type label plain colored
    current_row=$(get_cursor_row)
    ENTRY_ROW=()

    for i in "${!MENU_ENTRIES[@]}"; do
        IFS='|' read -r type label plain colored _ <<< "${MENU_ENTRIES[$i]}"
        if [[ "$type" == "HEADER" && "$i" != "0" ]]; then
            printf "\n"
            (( current_row++ ))
        fi

        ENTRY_ROW[$i]=$current_row
        if [[ "$type" == "HEADER" ]]; then
            render_header "$label"
            (( current_row++ ))
        else
            if [[ "${SELECTABLE[$SELECTED_IDX]}" == "$i" ]]; then
                print_sel_full "$plain"; printf '\n'
            else
                printf '%b\n' "$colored"
            fi
            (( current_row++ ))
        fi
    done

    printf "\n"
    printf '%b\n' "  ${DIM}${PTR} enter run ${SEP} ↑↓ move ${SEP} key jump ${SEP} q quit${NC}"
}

run_action() {
    local action="$1"
    case "$action" in
        status)
            printf "\n  ${CYAN}Running remote status...${NC}\n\n"
            run_child bash "$SCRIPT_DIR/core/ping.sh"
            return 0
            ;;
        wake)
            printf "\n  ${CYAN}Running remote wake...${NC}\n\n"
            run_child bash "$SCRIPT_DIR/core/wake.sh"
            return 0
            ;;
        mount)
            printf "\n  ${CYAN}Mounting remote shares...${NC}\n\n"
            run_child bash "$SCRIPT_DIR/core/mount.sh"
            return 0
            ;;
        mount_local)
            printf "\n  ${CYAN}Mounting shares via local network...${NC}\n\n"
            run_child bash "$SCRIPT_DIR/core/mount.sh" --local
            return 0
            ;;
        shutdown_remote)
            if ! confirm_danger "SHUT DOWN ALL REMOTE LINUX NODES AND WORKSTATION"; then
                printf "  ${YELLOW}Shutdown cancelled.${NC}\n"
                return 0
            fi
            run_child bash "$SCRIPT_DIR/core/shutdown.sh"
            return 0
            ;;
        unmount)
            if ! confirm_danger "UNMOUNT REMOTE SHARES"; then
                printf "  ${YELLOW}Unmount cancelled.${NC}\n"
                return 0
            fi
            printf "\n  ${CYAN}Running remote unmount...${NC}\n\n"
            run_child bash "$SCRIPT_DIR/core/unmount.sh"
            return 0
            ;;
        delcache)
            printf "\n  ${CYAN}Running local cache cleanup...${NC}\n\n"
            run_child bash "$SCRIPT_DIR/core/delcache.sh"
            return 0
            ;;
        farm)
            if [[ -z "${WORKSTATION_SSH_HOST:-}" || -z "${FARM_SCRIPT_PATH:-}" ]]; then
                printf "\n  ${RED}ERROR:${NC} WORKSTATION_SSH_HOST / FARM_SCRIPT_PATH not set.\n"
                printf "  Copy config/secrets.example.sh to config/secrets.sh and fill in your values.\n"
                return 0
            fi
            printf "\n  ${CYAN}Connecting to workstation farm menu...${NC}\n\n"
            run_child ssh -t "$WORKSTATION_SSH_HOST" "$FARM_SCRIPT_PATH; bash -l"
            return 1
            ;;
        quit)
            quit_menu
            ;;
    esac
    return 0
}

execute_selected() {
    local action ret
    IFS='|' read -r _ _ _ _ action <<< "${MENU_ENTRIES[${SELECTABLE[$SELECTED_IDX]}]}"
    IN_MENU=0
    tput cnorm
    run_action "$action"
    ret=$?

    stty sane 2>/dev/null
    tput sgr0
    tput cnorm

    if [ $ret -eq 0 ]; then
        printf "\n"
        read -n 1 -s -r -p "  Press any key to return to the menu..."
    fi
    # Rebuild so live hints (mounted-share count) reflect the action.
    build_menu
    render_menu
    IN_MENU=1
    tput cnorm
}

build_menu
SELECTED_IDX=0

tput civis
render_menu
IN_MENU=1
tput cnorm

while true; do
    key=""
    IFS= read -rsn1 -t 1 key
    ret=$?

    if (( ret > 128 )); then
        continue
    fi

    if [[ "$key" == $'\x1b' ]]; then
        read -rsn2 -t 1 key2
        case "$key2" in
            '[A')
                if (( SELECTED_IDX > 0 )); then
                    old="${SELECTABLE[$SELECTED_IDX]}"
                    (( SELECTED_IDX-- ))
                    new="${SELECTABLE[$SELECTED_IDX]}"
                    render_item "$old" 0
                    render_item "$new" 1
                fi
                ;;
            '[B')
                if (( SELECTED_IDX < ${#SELECTABLE[@]} - 1 )); then
                    old="${SELECTABLE[$SELECTED_IDX]}"
                    (( SELECTED_IDX++ ))
                    new="${SELECTABLE[$SELECTED_IDX]}"
                    render_item "$old" 0
                    render_item "$new" 1
                fi
                ;;
        esac
    elif [[ $ret -eq 0 && "$key" == "" ]]; then
        execute_selected
    elif [[ -n "$key" ]]; then
        key="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
        if [[ "$key" == "q" ]]; then
            quit_menu
        fi
        idx="$(entry_index_for_shortcut "$key")"
        if [[ -n "$idx" ]]; then
            old="${SELECTABLE[$SELECTED_IDX]}"
            SELECTED_IDX="$idx"
            new="${SELECTABLE[$SELECTED_IDX]}"
            render_item "$old" 0
            render_item "$new" 1
            execute_selected
        fi
    fi
done
