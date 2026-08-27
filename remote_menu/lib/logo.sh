#!/bin/bash

# The logo fades top-to-bottom through a color gradient: smooth RGB
# interpolation on truecolor terminals (iTerm2, newer Terminal.app),
# 5-step 256-color gradients otherwise, single classic ANSI color as
# the last fallback. Bash 3.2 compatible (macOS default).
LOGO_256=0
if [ "$(tput colors 2>/dev/null || echo 8)" -ge 256 ]; then
  LOGO_256=1
fi
LOGO_TC=0
case "${COLORTERM:-}" in
  truecolor|24bit) LOGO_TC=1 ;;
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

pick_gradient() {
  if [ "$LOGO_256" -eq 1 ]; then
    printf '%s' "$(( RANDOM % ${#TC_GRADIENTS[@]} ))"
  else
    printf '%s' "$(( RANDOM % ${#CLASSIC_COLORS[@]} ))"
  fi
}

# print_logo <gradient index>  (a non-numeric arg is treated as a raw
# escape color for backwards compatibility)
print_logo() {
  local gi="${1:-0}" i=0 n=${#LOGO_LINES[@]} color
  case "$gi" in
    *[!0-9]*)
      while [ "$i" -lt "$n" ]; do
        echo -e "${gi}${BOLD}${LOGO_LINES[$i]}${NC}"
        i=$((i+1))
      done
      echo ""
      return 0
      ;;
  esac
  if [ "$LOGO_TC" -eq 1 ]; then
    local sr sg sb er eg eb r g b
    IFS=' |' read -r sr sg sb er eg eb <<< "${TC_GRADIENTS[$gi]}"
    while [ "$i" -lt "$n" ]; do
      r=$(( sr + (er - sr) * i / (n - 1) ))
      g=$(( sg + (eg - sg) * i / (n - 1) ))
      b=$(( sb + (eb - sb) * i / (n - 1) ))
      echo -e "\033[38;2;${r};${g};${b}m${BOLD}${LOGO_LINES[$i]}${NC}"
      i=$((i+1))
    done
  elif [ "$LOGO_256" -eq 1 ]; then
    local grad=(${THEME_GRADIENTS[$gi]})
    while [ "$i" -lt "$n" ]; do
      echo -e "\033[38;5;${grad[$i]}m${BOLD}${LOGO_LINES[$i]}${NC}"
      i=$((i+1))
    done
  else
    color="\033[${CLASSIC_COLORS[$gi]}m"
    while [ "$i" -lt "$n" ]; do
      echo -e "${color}${BOLD}${LOGO_LINES[$i]}${NC}"
      i=$((i+1))
    done
  fi
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
