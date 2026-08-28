#!/bin/bash

# Braille spinner for the remote scripts (macOS + Linux): spin_start
# "label" ... spin_stop. Animates only on a tty; on non-tty output the
# label is printed once so logs stay readable. Bash 3.2 compatible.
SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
SPIN_PID=""
SPIN_COLOR=$'\033[94m'
SPIN_RESET=$'\033[0m'
SPIN_DIM=$'\033[2m'
case "${COLORTERM:-}" in
  truecolor|24bit)
    SPIN_COLOR=$'\033[38;2;135;215;255m'   # UI accent #87d7ff
    ;;
  *)
    if [ "$(tput colors 2>/dev/null || echo 8)" -ge 256 ]; then
      SPIN_COLOR=$'\033[38;5;117m'
    fi
    ;;
esac

spin_start() {
  local label="$1"
  spin_stop
  if [ ! -t 1 ]; then
    echo "  $label"
    return 0
  fi
  # Truncate so prefix + label + elapsed suffix never wrap: a wrapped
  # spinner line breaks the \r redraw and spams new lines.
  local cols max
  cols=$(tput cols 2>/dev/null)
  case "$cols" in
    ''|*[!0-9]*) cols="${COLUMNS:-60}" ;;
  esac
  max=$(( cols - 12 ))
  [ "$max" -lt 10 ] && max=10
  if [ "${#label}" -gt "$max" ]; then
    label="${label:0:$((max-3))}..."
  fi
  tput civis 2>/dev/null
  (
    trap 'exit 0' TERM
    i=0
    secs=0
    elapsed=""
    while :; do
      # Dim elapsed-seconds suffix once a wait takes >= 1s.
      secs=$(( i * 8 / 100 ))
      elapsed=""
      [ "$secs" -ge 1 ] && elapsed=" ${secs}s"
      printf '\r\033[K  %s%s%s %s%s%s%s' \
        "$SPIN_COLOR" "${SPIN_FRAMES[$(( i % ${#SPIN_FRAMES[@]} ))]}" "$SPIN_RESET" \
        "$label" "$SPIN_DIM" "$elapsed" "$SPIN_RESET"
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
