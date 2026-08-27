#!/bin/bash

# === LOGO ANIMATION MODULE START ===
# The logo fades top-to-bottom through a color gradient: smooth RGB
# interpolation on truecolor terminals, 5-step 256-color gradients
# otherwise, single classic ANSI color as the last fallback.
HDR_256=0
if [ "$(tput colors 2>/dev/null || echo 8)" -ge 256 ]; then
    HDR_256=1
fi
HDR_TC=0
case "${COLORTERM:-}" in
    truecolor|24bit) HDR_TC=1 ;;
esac

# Truecolor gradients: "start_r start_g start_b|end_r end_g end_b".
TC_GRADIENTS=(
    "125 211 252|59 130 246"    # aqua -> blue
    "167 243 208|52 211 153"    # mint -> green
    "249 168 212|167 139 250"   # pink -> violet
    "253 230 138|251 146 60"    # cream -> amber
    "186 230 253|129 140 248"   # ice -> periwinkle
)
# 256-color gradients (one index per logo line).
THEME_GRADIENTS=(
    "123 87 81 75 69"       # aqua -> blue
    "158 121 114 78 72"     # mint -> green
    "219 213 207 177 141"   # pink -> violet
    "229 223 222 216 215"   # cream -> amber
    "159 117 111 105 99"    # ice -> periwinkle
)
# Classic ANSI fallback (single color per run).
CLASSIC_COLORS=('0;31' '0;32' '0;33' '0;34' '0;35' '1;31' '1;32' '1;33' '1;34' '1;35' '1;36')
BOLD='\033[1m'
NC='\033[0m'

LOGO_LINES=(
'       _____                          __'
'      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___'
'     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<'
'     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/'
'             /___/'
)

function pick_logo_gradient() {
    if [ "$HDR_256" -eq 1 ]; then
        echo $(( RANDOM % ${#TC_GRADIENTS[@]} ))
    else
        echo $(( RANDOM % ${#CLASSIC_COLORS[@]} ))
    fi
}

# print_logo <gradient index>
function print_logo() {
    local gi="${1:-0}" i n=${#LOGO_LINES[@]} color
    if [ "$HDR_TC" -eq 1 ]; then
        local sr sg sb er eg eb r g b
        IFS=' |' read -r sr sg sb er eg eb <<< "${TC_GRADIENTS[$gi]}"
        for (( i=0; i<n; i++ )); do
            r=$(( sr + (er - sr) * i / (n - 1) ))
            g=$(( sg + (eg - sg) * i / (n - 1) ))
            b=$(( sb + (eb - sb) * i / (n - 1) ))
            echo -e "\033[38;2;${r};${g};${b}m${BOLD}${LOGO_LINES[$i]}${NC}"
        done
    elif [ "$HDR_256" -eq 1 ]; then
        local -a grad=(${THEME_GRADIENTS[$gi]})
        for (( i=0; i<n; i++ )); do
            echo -e "\033[38;5;${grad[$i]}m${BOLD}${LOGO_LINES[$i]}${NC}"
        done
    else
        color="\033[${CLASSIC_COLORS[$gi]}m"
        for (( i=0; i<n; i++ )); do
            echo -e "${color}${BOLD}${LOGO_LINES[$i]}${NC}"
        done
    fi
    echo ""
}

function play_logo_animation() {
    clear
    tput civis # Hide cursor during animation
    for i in {1..5}; do
        tput cup 0 0
        print_logo "$(pick_logo_gradient)"
        sleep 0.03
    done
    tput cup 0 0
    print_logo "$(pick_logo_gradient)"
    tput cnorm # Show cursor when done
}

play_logo_animation
