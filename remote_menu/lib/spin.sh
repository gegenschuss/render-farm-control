#!/bin/bash

# Braille spinner for the remote (mac) scripts: spin_start "label" ...
# spin_stop. Animates only on a tty; on non-tty output the label is
# printed once so logs stay readable. Bash 3.2 compatible.
SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
SPIN_PID=""
SPIN_COLOR=$'\033[36m'
SPIN_RESET=$'\033[0m'
if [ "$(tput colors 2>/dev/null || echo 8)" -ge 256 ]; then
  SPIN_COLOR=$'\033[38;5;81m'
fi

spin_start() {
  local label="$1"
  spin_stop
  if [ ! -t 1 ]; then
    echo "  $label"
    return 0
  fi
  tput civis 2>/dev/null
  (
    trap 'exit 0' TERM
    i=0
    while :; do
      printf '\r\033[K  %s%s%s %s' \
        "$SPIN_COLOR" "${SPIN_FRAMES[$(( i % ${#SPIN_FRAMES[@]} ))]}" "$SPIN_RESET" "$label"
      i=$(( i + 1 ))
      sleep 0.08
    done
  ) &
  SPIN_PID=$!
}

# Stops the spinner and clears its line; follow with your result output.
spin_stop() {
  [ -n "$SPIN_PID" ] || return 0
  kill "$SPIN_PID" 2>/dev/null
  wait "$SPIN_PID" 2>/dev/null
  SPIN_PID=""
  if [ -t 1 ]; then
    printf '\r\033[K'
    tput cnorm 2>/dev/null
  fi
  return 0
}
