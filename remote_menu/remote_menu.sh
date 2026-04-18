#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
export LC_ALL=en_US.UTF-8

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat << 'EOF'
Usage: ./remote_menu.sh

Interactive launcher for:
  - core/ping.sh
  - core/wake.sh
  - core/unmount.sh

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

NC='\033[0m'
BOLD='\033[1m'
REVERSE='\033[7m'
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'

LINE_WIDTH=58
MENU_ENTRIES=()
SELECTABLE=()
ENTRY_ROW=()
SELECTED_IDX=0

trap 'clear; tput cnorm; printf "\n${GREEN}Exiting Remote Menu.${NC}\n"; exit 0' SIGINT SIGTERM

confirm_danger() {
    local action_label="$1"
    tput cnorm
    printf "\n${YELLOW}${BOLD}ATTENTION:${NC} You are about to ${RED}%s${NC}\n" "$action_label"
    read -n 1 -r -p "$(printf "${RED}Are you sure? [y/N]: ${NC}")" confirm
    printf "\n"
    tput civis
    [[ "$confirm" =~ ^[Yy]$ ]]
}

make_line() {
    local shortcut="$1" label="$2" hint="$3"
    local prefix="  ${shortcut}) "
    local plain="${prefix}${label}"
    local pad=$(( LINE_WIDTH - ${#plain} - ${#hint} ))
    (( pad < 1 )) && pad=1
    local spaces
    printf -v spaces "%${pad}s" ""
    PLAIN_OUT="${prefix}${label}${spaces}${hint}"
    COLOR_OUT="  ${GREEN}${shortcut}${NC}) ${label}${spaces}${hint}"
    if [[ "$shortcut" == "q" ]]; then
        COLOR_OUT="  ${RED}${shortcut}${NC}) ${BOLD}${label}${NC}${spaces}${hint}"
    fi
}

build_menu() {
    MENU_ENTRIES=()
    SELECTABLE=()

    MENU_ENTRIES+=( "HEADER|=== REMOTE STATUS ==========================================" )
    make_line "f" "Login"    "SSH to workstation farm menu"
    MENU_ENTRIES+=( "ITEM|f|${PLAIN_OUT}|${COLOR_OUT}|farm" )
    make_line "s" "Ping"  "Ping remote nodes"
    MENU_ENTRIES+=( "ITEM|s|${PLAIN_OUT}|${COLOR_OUT}|status" )
    make_line ""
    MENU_ENTRIES+=( "HEADER|=== REMOTE START ===========================================" )
    make_line "w" "Start"    "Wake + mount + connect"
    MENU_ENTRIES+=( "ITEM|w|${PLAIN_OUT}|${COLOR_OUT}|wake" )
    make_line ""
    MENU_ENTRIES+=( "HEADER|=== REMOTE SHUTDOWN ========================================" )
    make_line "u" "Unmount" "Close monitor + unmount shares"
    MENU_ENTRIES+=( "ITEM|u|${PLAIN_OUT}|${COLOR_OUT}|unmount" )
    make_line "x" "Shutdown" "Shutdown remote linux workstation & nodes"
    MENU_ENTRIES+=( "ITEM|x|${PLAIN_OUT}|${COLOR_OUT}|shutdown_remote" )
    MENU_ENTRIES+=( "HEADER|============================================================" )
    make_line "q" "Exit" ""
    MENU_ENTRIES+=( "ITEM|q|${PLAIN_OUT}|  ${RED}q${NC}) ${BOLD}Exit${NC}|quit" )

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
        printf "${REVERSE}${plain}${NC}"
    else
        printf "${colored}"
    fi
    tput rc
}

render_menu() {
    clear
    tput civis
    if [ "$HAS_LOGO" -eq 1 ] && declare -F print_logo >/dev/null 2>&1; then
        local logo_color="$CYAN"
        if declare -p THEME_COLORS >/dev/null 2>&1; then
            logo_color="${THEME_COLORS[$RANDOM % ${#THEME_COLORS[@]}]}"
        fi
        print_logo "$logo_color"
        printf "${NC}\n"
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
            printf "${CYAN}${BOLD}${label}${NC}\n"
            (( current_row++ ))
        else
            if [[ "${SELECTABLE[$SELECTED_IDX]}" == "$i" ]]; then
                printf "${REVERSE}${plain}${NC}\n"
            else
                printf "${colored}\n"
            fi
            (( current_row++ ))
        fi
    done

    printf "\n"
    printf "  ${CYAN}↑↓ navigate   Enter/shortcut select   q quit${NC}\n"
}

run_action() {
    local action="$1"
    case "$action" in
        status)
            printf "\n${CYAN}Running remote status...${NC}\n\n"
            bash "$SCRIPT_DIR/core/ping.sh"
            return 0
            ;;
        wake)
            printf "\n${CYAN}Running remote wake...${NC}\n\n"
            bash "$SCRIPT_DIR/core/wake.sh"
            return 0
            ;;
        shutdown_remote)
            if ! confirm_danger "SHUT DOWN ALL REMOTE LINUX NODES AND WORKSTATION"; then
                printf "${YELLOW}Shutdown cancelled.${NC}\n"
                return 0
            fi
            bash "$SCRIPT_DIR/core/shutdown.sh"
            return 0
            ;;
        unmount)
            if ! confirm_danger "UNMOUNT REMOTE SHARES"; then
                printf "${YELLOW}Unmount cancelled.${NC}\n"
                return 0
            fi
            printf "\n${CYAN}Running remote unmount...${NC}\n\n"
            bash "$SCRIPT_DIR/core/unmount.sh"
            return 0
            ;;
        farm)
            printf "\n${CYAN}Connecting to workstation farm menu...${NC}\n\n"
            ssh -t "$WORKSTATION_SSH_HOST" "$FARM_SCRIPT_PATH; bash -l"
            return 1
            ;;
        quit)
            clear
            tput cnorm
            printf "\n${GREEN}Exiting Remote Menu.${NC}\n"
            exit 0
            ;;
    esac
    return 0
}

execute_selected() {
    local action ret
    IFS='|' read -r _ _ _ _ action <<< "${MENU_ENTRIES[${SELECTABLE[$SELECTED_IDX]}]}"
    tput cnorm
    run_action "$action"
    ret=$?

    stty sane 2>/dev/null
    tput sgr0
    tput cnorm

    if [ $ret -eq 0 ]; then
        printf "\n"
        read -n 1 -s -r -p "Press any key to return to the menu..."
    fi
    render_menu
    tput cnorm
}

build_menu
SELECTED_IDX=0

tput civis
render_menu
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
    elif [[ "$key" == "q" ]]; then
        clear
        tput cnorm
        printf "\n${GREEN}Exiting Remote Menu.${NC}\n"
        exit 0
    elif [[ -n "$key" ]]; then
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
