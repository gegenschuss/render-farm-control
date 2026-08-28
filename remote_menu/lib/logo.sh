#!/bin/bash
# Solid warm-yellow logo (#FFF954, the SilverBullet page-title color):
# 256-color 227, classic bright yellow as the last fallback. Bash 3.2
# compatible (macOS default); runs on macOS and Linux.
LOGO_COLOR='\033[1;33m'
if [ "$(tput colors 2>/dev/null || echo 8)" -ge 256 ]; then
  LOGO_COLOR='\033[38;5;227m'
fi
case "${COLORTERM:-}" in
  truecolor|24bit) LOGO_COLOR='\033[38;2;255;249;84m' ;;
esac
BOLD='\033[1m'
NC='\033[0m'

LOGO_LINES=(
' _____                         _'
'|   __|___ ___ ___ ___ ___ ___| |_ _ _ ___ ___'
'|  |  | -_| . | -_|   |_ -|  _|   | | |_ -|_ -|'
'|_____|___|_  |___|_|_|___|___|_|_|___|___|___|'
'          |___|'
'                               farm-control'
)

# Center the art in the 60-column UI: shift every line by the same pad
# derived from the widest line, so the internal alignment is kept.
LOGO_WIDTH=60
_logo_longest=0
for _logo_line in "${LOGO_LINES[@]}"; do
  [ "${#_logo_line}" -gt "$_logo_longest" ] && _logo_longest=${#_logo_line}
done
_logo_pad_n=$(( (LOGO_WIDTH - _logo_longest) / 2 ))
[ "$_logo_pad_n" -lt 0 ] && _logo_pad_n=0
printf -v LOGO_PAD "%${_logo_pad_n}s" ""
unset _logo_longest _logo_line _logo_pad_n

# Kept for callers that pass a gradient index; the palette is fixed now.
pick_gradient() {
  printf '0'
}

# print_logo [ignored] — always renders the solid accent logo.
print_logo() {
  local i=0 n=${#LOGO_LINES[@]} style
  while [ "$i" -lt "$n" ]; do
    # Tagline (last line) stays regular weight; the art is bold.
    style="$BOLD"
    [ "$i" -eq $((n-1)) ] && style=""
    echo -e "${LOGO_PAD}${LOGO_COLOR}${style}${LOGO_LINES[$i]}${NC}"
    i=$((i+1))
  done
  echo ""
}

# With a fixed palette there is nothing to animate: clear and print once.
play_logo_animation() {
  clear
  print_logo
}
