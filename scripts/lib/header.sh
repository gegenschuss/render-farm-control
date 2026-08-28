#!/bin/bash

# === LOGO MODULE START ===
# Solid accent-colored logo: light blue #87d7ff on truecolor terminals,
# 256-color 117, classic bright blue as the last fallback.
HDR_COLOR='\033[94m'
if [ "$(tput colors 2>/dev/null || echo 8)" -ge 256 ]; then
    HDR_COLOR='\033[38;5;117m'
fi
case "${COLORTERM:-}" in
    truecolor|24bit) HDR_COLOR='\033[38;2;135;215;255m' ;;
esac
BOLD='\033[1m'
NC='\033[0m'

LOGO_LINES=(
' _____                         _'
'|   __|___ ___ ___ ___ ___ ___| |_ _ _ ___ ___'
'|  |  | -_| . | -_|   |_ -|  _|   | | |_ -|_ -|'
'|_____|___|_  |___|_|_|___|___|_|_|___|___|___|'
'          |___|'
)

# Center the art in the 60-column UI: shift every line by the same pad
# derived from the widest line, so the internal alignment is kept.
LOGO_WIDTH=60
_logo_longest=0
for _logo_line in "${LOGO_LINES[@]}"; do
    (( ${#_logo_line} > _logo_longest )) && _logo_longest=${#_logo_line}
done
_logo_pad_n=$(( (LOGO_WIDTH - _logo_longest) / 2 ))
(( _logo_pad_n < 0 )) && _logo_pad_n=0
printf -v LOGO_PAD "%${_logo_pad_n}s" ""
unset _logo_longest _logo_line _logo_pad_n

function print_logo() {
    local i n=${#LOGO_LINES[@]}
    for (( i=0; i<n; i++ )); do
        echo -e "${LOGO_PAD}${HDR_COLOR}${BOLD}${LOGO_LINES[$i]}${NC}"
    done
    echo ""
}

# With a fixed palette there is nothing to animate: clear and print once.
function play_logo_animation() {
    clear
    print_logo
}

play_logo_animation
