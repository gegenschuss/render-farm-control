#!/bin/bash

# The logo fades top-to-bottom through a color gradient on 256-color
# terminals (Terminal.app/iTerm2 both support 256 colors), single
# classic ANSI color as fallback. Bash 3.2 compatible (macOS default).
LOGO_256=0
if [ "$(tput colors 2>/dev/null || echo 8)" -ge 256 ]; then
  LOGO_256=1
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
LOGO_DIM='\033[38;5;242m'
[ "$LOGO_256" -eq 1 ] || LOGO_DIM='\033[2m'

LOGO_LINES=(
'       _____                          __'
'      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___'
'     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<'
'     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/'
'             /___/'
)

pick_gradient() {
  printf '%s' "${THEME_GRADIENTS[$(( RANDOM % ${#THEME_GRADIENTS[@]} ))]}"
}

# print_logo <gradient> — gradient is a space-separated list of 256-color
# indices (one per logo line), or a single classic "attr;color" pair.
print_logo() {
  local grad=($1)
  local i=0 color
  while [ "$i" -lt "${#LOGO_LINES[@]}" ]; do
    if [ "$LOGO_256" -eq 1 ] && [ "${#grad[@]}" -ge "${#LOGO_LINES[@]}" ]; then
      color="\033[38;5;${grad[$i]}m"
    else
      color="\033[${grad[0]}m"
    fi
    echo -e "${color}${BOLD}${LOGO_LINES[$i]}${NC}"
    i=$((i+1))
  done
  echo ""
  echo -e "${LOGO_DIM}                              remote control${NC}"
  echo ""
}

play_logo_animation() {
  clear
  tput civis
  for _ in 1 2 3 4 5; do
    tput cup 0 0
    print_logo "$(pick_gradient)"
    sleep 0.03
  done
  tput cup 0 0
  print_logo "$(pick_gradient)"
  tput cnorm
}
