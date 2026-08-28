#!/bin/bash
#  _____                         _
# |   __|___ ___ ___ ___ ___ ___| |_ _ _ ___ ___
# |  |  | -_| . | -_|   |_ -|  _|   | | |_ -|_ -|
# |_____|___|_  |___|_|_|___|___|_|_|___|___|___|
#           |___|
#
# Shared UI + platform helpers for the remote menu scripts.
# Palette: black & white plus ONE accent (#87d7ff); red/green are
# reserved for failed/good status. Bash 3.2 compatible (macOS stock
# bash); runs on macOS and Linux.

UI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 56 content cols + 2-space margins each side, matching the Linux UI.
WIDTH=56

UI_OS="linux"
[ "$(uname -s)" = "Darwin" ] && UI_OS="mac"

# Make sure UTF-8 glyphs render even when the caller's locale is bare C.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]*) ;;
  *)
    if locale -a 2>/dev/null | grep -qi '^en_US\.utf-\{0,1\}8$'; then
      export LC_ALL=en_US.UTF-8
    elif locale -a 2>/dev/null | grep -qi '^C\.utf-\{0,1\}8$'; then
      export LC_ALL=C.UTF-8
    fi
    ;;
esac

# --- PALETTE ---
# SilverBullet theme: blue UI accent (#299CF0), warm-yellow headers
# (#FFF954 / #E8D42A), mint OK (#7EEAAA), warm-cream bold warnings
# (#FFF8C4), muted gray dim (#9AA0A6); red only for FAIL/danger.
ui_init_colors() {
  C_RESET="" C_BOLD="" C_DIM="" C_ACCENT="" C_H1="" C_H2="" C_OK="" C_FAIL="" UI_SEL_ON=""
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_OK=$'\033[32m'
    C_FAIL=$'\033[31m'
    C_H1=$'\033[1;33m'
    C_H2=$'\033[33m'
    C_WARN="$C_BOLD"
    case "${COLORTERM:-}" in
      truecolor|24bit)
        C_ACCENT=$'\033[38;2;41;156;240m'
        C_H1=$'\033[38;2;255;249;84m'
        C_H2=$'\033[38;2;232;212;42m'
        C_OK=$'\033[38;2;126;234;170m'
        C_WARN=$'\033[1;38;2;255;248;196m'
        C_DIM=$'\033[38;2;154;160;166m'
        UI_SEL_ON=$'\033[48;2;41;156;240m\033[38;2;20;20;20m\033[1m'
        ;;
      *)
        if [ "$(tput colors 2>/dev/null || echo 8)" -ge 256 ]; then
          C_ACCENT=$'\033[38;5;39m'
          C_H1=$'\033[38;5;227m'
          C_H2=$'\033[38;5;184m'
          C_OK=$'\033[38;5;115m'
          C_WARN=$'\033[1;38;5;230m'
          C_DIM=$'\033[38;5;247m'
          UI_SEL_ON=$'\033[48;5;39m\033[38;5;235m\033[1m'
        else
          C_ACCENT=$'\033[94m'
          UI_SEL_ON=$'\033[7m\033[1m'
        fi
        ;;
    esac
  elif [ -t 1 ]; then
    UI_SEL_ON=$'\033[7m'
  fi
  # Semantic names used by the scripts (old names kept as aliases).
  C_INFO="$C_ACCENT"
  C_HEAD="$C_H2"
  C_SUB="$C_DIM"
  : "${C_WARN:=$C_BOLD}"
}
ui_init_colors

# --- SPINNER ---
[ -f "$UI_LIB_DIR/spin.sh" ] && source "$UI_LIB_DIR/spin.sh"
if [ -z "${SPIN_FRAMES:-}" ]; then
  SPIN_FRAMES=('|' '/' '-' '\')
  SPIN_COLOR="" SPIN_RESET="" SPIN_DIM=""
  spin_start() { echo "  $1"; }
  spin_stop() { :; }
fi

# --- GLYPHS ---
# Box-drawing glyphs when the locale is UTF-8, ASCII otherwise.
UI_UTF8=0
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]*) UI_UTF8=1 ;;
esac
if [ "$UI_UTF8" -eq 1 ]; then
  UI_G_RULE='─'
  UI_G_TL='╭'
  UI_G_TR='╮'
  UI_G_BL='╰'
  UI_G_BR='╯'
  UI_G_VBAR='│'
  UI_G_SECTION='▸'
  UI_G_OK='✔'
  UI_G_SEP='·'
else
  UI_G_RULE='-'
  UI_G_TL='+'
  UI_G_TR='+'
  UI_G_BL='+'
  UI_G_BR='+'
  UI_G_VBAR='|'
  UI_G_SECTION='>'
  UI_G_OK='[OK]'
  UI_G_SEP='|'
fi

# --- OUTPUT HELPERS ---
ts() { date '+%H:%M:%S'; }

ui_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ui_rule_str <count> — repeat the rule glyph (while loop: bash 3.2,
# and tr can't emit multibyte glyphs).
ui_rule_str() {
  local i=0 out=""
  while [ "$i" -lt "$1" ]; do
    out="$out$UI_G_RULE"
    i=$((i+1))
  done
  printf '%s' "$out"
}

log() {
  local level="$1"; shift
  local msg="$*" color=""
  case "$level" in
    INFO) color="$C_ACCENT" ;;
    OK)   color="$C_OK" ;;
    WARN) color="$C_BOLD" ;;
    FAIL) color="$C_FAIL" ;;
    SKIP) color="$C_DIM" ;;
  esac
  printf '  [%s] %b%-5s%b %s\n' "$(ts)" "$color" "$level" "$C_RESET" "$msg"
}

pass() { log "OK"   "$1"; }
warn() { log "WARN" "$1"; }
fail() { log "FAIL" "$1"; }
info() { log "INFO" "$1"; }
skip() { log "SKIP" "$1"; }

# Rounded box around the title (ASCII "+--+" on non-UTF-8 locales).
# Titles display lowercase regardless of how call sites shout.
header() {
  local text inner line pad spaces
  text=$(ui_lower "$1")
  inner=$(( WIDTH - 2 ))
  line=$(ui_rule_str "$inner")
  pad=$(( inner - ${#text} - 3 ))
  [ "$pad" -lt 0 ] && pad=0
  printf -v spaces "%${pad}s" ""
  printf '  %s%s%s\n' "$C_DIM" "${UI_G_TL}${line}${UI_G_TR}" "$C_RESET"
  printf '  %s%s%s  %s%s%s%s %s%s%s\n' \
    "$C_DIM" "$UI_G_VBAR" "$C_RESET" \
    "${C_BOLD}${C_ACCENT}" "$text" "$C_RESET" "$spaces" \
    "$C_DIM" "$UI_G_VBAR" "$C_RESET"
  printf '  %s%s%s\n' "$C_DIM" "${UI_G_BL}${line}${UI_G_BR}" "$C_RESET"
}

section() {
  echo
  printf '  %s%s %s%s\n' "$C_ACCENT" "$UI_G_SECTION" "$(ui_lower "$1")" "$C_RESET"
  echo
}

# One-line boxed end-of-run summary (pass plain text only — colors would
# break the width math), e.g.: ui_summary "3 unmounted · 1 skipped"
ui_summary() {
  local text inner line pad spaces
  text=$(ui_lower "$1")
  inner=$(( WIDTH - 2 ))
  line=$(ui_rule_str "$inner")
  pad=$(( inner - ${#text} - 4 - ${#UI_G_OK} ))
  [ "$pad" -lt 0 ] && pad=0
  printf -v spaces "%${pad}s" ""
  printf '  %s%s%s\n' "$C_DIM" "${UI_G_TL}${line}${UI_G_TR}" "$C_RESET"
  printf '  %s%s%s %s%s%s  %s%s %s%s%s\n' \
    "$C_DIM" "$UI_G_VBAR" "$C_RESET" \
    "$C_OK" "$UI_G_OK" "$C_RESET" \
    "$text" "$spaces" \
    "$C_DIM" "$UI_G_VBAR" "$C_RESET"
  printf '  %s%s%s\n' "$C_DIM" "${UI_G_BL}${line}${UI_G_BR}" "$C_RESET"
}

# --- LOGO ---
ui_play_logo() {
  if [ -f "$UI_LIB_DIR/logo.sh" ]; then
    source "$UI_LIB_DIR/logo.sh"
    play_logo_animation
  fi
}

# --- SECRETS ---
# ui_require_secrets <caller SCRIPT_DIR>: load ../config/secrets.sh or die.
ui_require_secrets() {
  local caller_dir="$1"
  if [ ! -f "$caller_dir/../config/secrets.sh" ]; then
    echo "  ERROR: config/secrets.sh not found" >&2
    echo "  Copy config/secrets.example.sh to config/secrets.sh and fill in your values." >&2
    exit 1
  fi
  source "$caller_dir/../config/secrets.sh"
}

# --- EXIT PROMPT ---
# Wait for Enter only when run standalone; the menu adds its own
# "press any key" prompt (it exports REMOTE_MENU_ACTIVE=1).
ui_wait_exit() {
  [ -n "${REMOTE_MENU_ACTIVE:-}" ] && return 0
  echo
  read -r -p "  Press Enter to exit..."
}

# --- PLATFORM HELPERS ---
# One ping with a 1s timeout (-W is milliseconds on macOS, seconds on Linux).
ui_ping() {
  if [ "$UI_OS" = "mac" ]; then
    ping -c 1 -W 1000 "$1" >/dev/null 2>&1
  else
    ping -c 1 -W 1 "$1" >/dev/null 2>&1
  fi
}

# Path to the tailscale CLI, or failure if not installed.
tailscale_bin() {
  if command -v tailscale >/dev/null 2>&1; then
    printf 'tailscale'
  elif [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
    printf '/Applications/Tailscale.app/Contents/MacOS/Tailscale'
  else
    return 1
  fi
}

# Linux gvfs directory for a mounted SMB share (empty if not mounted).
ui_gvfs_dir() {
  find "/run/user/$(id -u)/gvfs" -maxdepth 1 -iname "*share=$1*" 2>/dev/null | head -n 1
}

# share_mounted <share>: is the SMB share currently mounted?
share_mounted() {
  local share="$1"
  if [ "$UI_OS" = "mac" ]; then
    # Trailing space so "studio" does not match "studio2".
    mount 2>/dev/null | grep -qi "/Volumes/$share "
  else
    [ -n "$(ui_gvfs_dir "$share")" ]
  fi
}

# Poll until the share shows up (mounts are asynchronous on both OSes),
# with a spinner while waiting.
ui_wait_mounted() {
  local share="$1" tries="${MOUNT_WAIT_SECONDS:-5}" i=0 ok=1
  spin_start "waiting for mount: $share"
  while [ "$i" -lt "$tries" ]; do
    if share_mounted "$share"; then
      ok=0
      break
    fi
    sleep 1
    i=$((i+1))
  done
  [ "$ok" -ne 0 ] && share_mounted "$share" && ok=0
  spin_stop
  return "$ok"
}

# mount_share <user> <host> <share>
# macOS: osascript "mount volume" with Finder fallback (Keychain creds).
# Linux: gio mount (gvfs; stored keyring credentials).
mount_share() {
  local user="$1" host="$2" share="$3"
  local url="smb://$user@$host/$share"

  if share_mounted "$share"; then
    pass "Already mounted: $share"
    return 0
  fi

  log "INFO" "Mounting: $url"
  if [ "$UI_OS" = "mac" ]; then
    if ! osascript -e "mount volume \"$url\"" >/dev/null 2>&1; then
      warn "Direct mount failed for $share; trying Finder fallback"
      if ! open -g "$url"; then
        fail "Failed to request mount for $share"
        warn "Check Keychain credential for $user@$host"
        return 1
      fi
    fi
  else
    if ! command -v gio >/dev/null 2>&1; then
      fail "gio not found (install glib2/gvfs to mount SMB shares)"
      return 1
    fi
    if ! gio mount "$url" >/dev/null 2>&1; then
      fail "gio mount failed for $url"
      warn "Check the stored keyring credential for $user@$host"
      return 1
    fi
  fi

  if ui_wait_mounted "$share"; then
    pass "Mounted: $share"
  else
    warn "Mount requested but $share not detected yet"
    return 1
  fi
}

# unmount_share <share>
unmount_share() {
  local share="$1"

  if ! share_mounted "$share"; then
    pass "Already unmounted: $share"
    return 0
  fi

  if [ "$UI_OS" = "mac" ]; then
    local mount_point="/Volumes/$share"
    log "INFO" "Unmounting: $mount_point"
    if diskutil unmount "$mount_point" >/dev/null 2>&1; then
      pass "Unmounted: $mount_point"
      return 0
    fi
    warn "Normal unmount failed, trying force unmount"
    if diskutil unmount force "$mount_point" >/dev/null 2>&1; then
      pass "Force unmounted: $mount_point"
      return 0
    fi
    fail "Could not unmount: $mount_point"
    return 1
  fi

  local dir
  dir="$(ui_gvfs_dir "$share")"
  log "INFO" "Unmounting: $share"
  if [ -n "$dir" ] && gio mount -u "$dir" >/dev/null 2>&1; then
    pass "Unmounted: $share"
    return 0
  fi
  fail "Could not unmount: $share"
  return 1
}
