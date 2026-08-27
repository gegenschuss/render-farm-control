#!/bin/bash

# === LOGO ANIMATION MODULE START ===
# The logo fades top-to-bottom through a color gradient on 256-color
# terminals; single classic ANSI color as fallback.
HDR_256=0
if [ "$(tput colors 2>/dev/null || echo 8)" -ge 256 ]; then
    HDR_256=1
    THEME_GRADIENTS=(
        "123 87 81 75 69"       # aqua -> blue
        "158 121 114 78 72"     # mint -> green
        "219 213 207 177 141"   # pink -> violet
        "229 223 222 216 215"   # cream -> amber
        "159 117 111 105 99"    # ice -> periwinkle
    )
else
    THEME_GRADIENTS=('0;31' '0;32' '0;33' '0;34' '0;35' '1;31' '1;32' '1;33' '1;34' '1;35' '1;36')
fi
BOLD='\033[1m'
NC='\033[0m'

LOGO_LINES=(
'       _____                          __'
'      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___'
'     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<'
'     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/'
'             /___/'
)

# print_logo <gradient> — gradient is a space-separated list of 256-color
# indices (one per logo line), or a single classic "attr;color" pair.
function print_logo() {
    local -a grad=($1)
    local i color
    for i in "${!LOGO_LINES[@]}"; do
        if [ "$HDR_256" -eq 1 ] && [ "${#grad[@]}" -ge "${#LOGO_LINES[@]}" ]; then
            color="\033[38;5;${grad[$i]}m"
        else
            color="\033[${grad[0]}m"
        fi
        echo -e "${color}${BOLD}${LOGO_LINES[$i]}${NC}"
    done
    echo ""
}

function play_logo_animation() {
    clear
    tput civis # Hide cursor during animation
    for i in {1..5}; do
        tput cup 0 0
        print_logo "${THEME_GRADIENTS[$RANDOM % ${#THEME_GRADIENTS[@]}]}"
        sleep 0.03
    done
    tput cup 0 0
    print_logo "${THEME_GRADIENTS[$RANDOM % ${#THEME_GRADIENTS[@]}]}"
    tput cnorm # Show cursor when done
}

play_logo_animation
