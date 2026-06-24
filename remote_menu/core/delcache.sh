#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
# macOS cache cleanup — default user cache paths for common VFX / Adobe apps.
export LC_ALL=en_US.UTF-8

WIDTH=60

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat << 'EOF'
Usage: ./delcache.sh

Interactive cleanup for macOS cache directories.
Apps covered:
  - Nuke, Mocha, SynthEyes, DaVinci Resolve
  - Adobe shared Media Cache (AE / Premiere / Media Encoder / Audition)
  - After Effects, Premiere Pro
  - Houdini render/sim project roots (via $HOUDINI_RENDER_ROOT / $HOUDINI_SIM_ROOT)

Override Houdini roots:
  HOUDINI_RENDER_ROOT=/Volumes/work/houdini/render ./delcache.sh
EOF
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/../lib/logo.sh" ]; then
  source "$SCRIPT_DIR/../lib/logo.sh"
fi

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_INFO=$'\033[36m'
  C_SUB=$'\033[35m'
  C_OK=$'\033[32m'
  C_WARN=$'\033[33m'
  C_FAIL=$'\033[31m'
else
  C_RESET=""
  C_BOLD=""
  C_INFO=""
  C_SUB=""
  C_OK=""
  C_WARN=""
  C_FAIL=""
fi

line_equals() {
  printf '%*s\n' "$WIDTH" '' | tr ' ' '='
}

subline() {
  printf '%*s\n' "$WIDTH" '' | tr ' ' '-'
}

ts() {
  date '+%H:%M:%S'
}

log() {
  local level="$1"
  shift
  local msg="$*"
  local color=""
  case "$level" in
    INFO) color="$C_INFO" ;;
    OK)   color="$C_OK" ;;
    WARN) color="$C_WARN" ;;
    FAIL) color="$C_FAIL" ;;
    SKIP) color="$C_SUB" ;;
  esac
  printf '[%s] %b%-5s%b %s\n' "$(ts)" "$color" "$level" "$C_RESET" "$msg"
}

pass()  { log "OK"   "$1"; }
warn()  { log "WARN" "$1"; }
fail()  { log "FAIL" "$1"; }
info()  { log "INFO" "$1"; }
skip()  { log "SKIP" "$1"; }

header() {
  echo
  line_equals
  printf '%b    %s%b\n' "${C_INFO}${C_BOLD}" "$1" "$C_RESET"
  line_equals
  echo
}

section() {
  echo
  subline
  printf '%b    %s%b\n' "${C_SUB}${C_BOLD}" "$1" "$C_RESET"
  subline
  echo
}

prompt_choice() {
  local question="$1"
  printf '%b%s%b ' "${C_WARN}${C_BOLD}" "$question" "$C_RESET"
  read -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Qq]$ ]]; then
    return 2
  fi
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    return 0
  fi
  return 1
}

# --- CONFIGURATION: FIXED PATHS ---
# nullglob so version-numbered Adobe folders expand cleanly, and missing
# patterns drop out instead of becoming literal strings.
shopt -s nullglob

# Nuke — disk cache lives under ~/Library/Caches on macOS
declare -a NUKE_PATHS=(
    "$HOME/Library/Caches/Nuke"
)

# Mocha Pro (Boris FX, older Imagineer Systems installs)
declare -a MOCHA_PATHS=(
    "$HOME"/Library/Application\ Support/Boris\ FX/Mocha*/Cache
    "$HOME"/Library/Application\ Support/Imagineer\ Systems/mocha*/Cache
    "$HOME/Library/Caches/Boris FX"
    "$HOME/Library/Caches/Imagineer Systems"
)

# SynthEyes
declare -a SYNTHEYES_PATHS=(
    "$HOME/Library/Caches/SynthEyes"
    "$HOME/Library/Application Support/SynthEyes/Cache"
)

# DaVinci Resolve (default gallery + clip cache; actual cache dir is
# configurable in Preferences > Media Storage — add it here if relocated)
declare -a RESOLVE_PATHS=(
    "$HOME/Movies/DaVinci Resolve/CacheClip"
    "$HOME/Movies/DaVinci Resolve/GalleryStills"
    "$HOME/Library/Application Support/Blackmagic Design/DaVinci Resolve/CacheClip"
    "$HOME/Library/Application Support/Blackmagic Design/DaVinci Resolve/GalleryStills"
)

# Shared Adobe media cache — AE, Premiere, Media Encoder, Audition all write here.
# Usually the biggest win on an Adobe machine.
declare -a ADOBE_MEDIA_CACHE_PATHS=(
    "$HOME/Library/Application Support/Adobe/Common/Media Cache Files"
    "$HOME/Library/Application Support/Adobe/Common/Media Cache"
    "$HOME/Library/Application Support/Adobe/Common/Peak Files"
)

# After Effects (disk cache + autosave/preview)
declare -a AE_PATHS=(
    "$HOME"/Library/Caches/Adobe/After\ Effects*
    "$HOME"/Library/Preferences/Adobe/After\ Effects*/Adobe\ After\ Effects\ Disk\ Cache*
)

# Premiere Pro (preview files + cache)
declare -a PREMIERE_PATHS=(
    "$HOME"/Library/Caches/Adobe/Premiere\ Pro*
    "$HOME"/Documents/Adobe/Premiere\ Pro/*/Video\ Previews
    "$HOME"/Documents/Adobe/Premiere\ Pro/*/Audio\ Previews
)

shopt -u nullglob

# --- CONFIGURATION: DYNAMIC PATHS ---
# Houdini render/sim roots are project-specific — set via env var if you keep
# per-project folders you want to prune interactively.
HOUDINI_RENDER_ROOT="${HOUDINI_RENDER_ROOT:-$HOME/houdini/render}"
HOUDINI_SIM_ROOT="${HOUDINI_SIM_ROOT:-$HOME/houdini/sim}"

# --- COUNTERS ---
CLEANED=0
SKIPPED=0
EMPTY=0

# --- FUNCTION 1: CLEAN & RESET (Keep Folder) ---
clean_defined_app() {
    local APP_NAME=$1
    # Bash 3.2 (macOS stock) lacks `local -n`; dereference the array by name
    # via indirect expansion instead.
    local ARR_NAME=$2
    local ARR_REF="${ARR_NAME}[@]"
    local -a PATHS_ARRAY=( "${!ARR_REF}" )

    section "$APP_NAME"

    local FOUND_ANY=false
    local DIR SIZE
    for DIR in "${PATHS_ARRAY[@]}"; do
        if [ -d "$DIR" ]; then
            SIZE=$(du -sh "$DIR" 2>/dev/null | cut -f1)
            info "Found: $DIR (${SIZE:-?})"
            FOUND_ANY=true
        fi
    done

    if [ "$FOUND_ANY" = false ]; then
        skip "No $APP_NAME cache directories found"
        EMPTY=$((EMPTY + 1))
        return
    fi

    prompt_choice "Purge contents of $APP_NAME? [y/N, q=cancel all]"
    local rc=$?
    if [ "$rc" -eq 2 ]; then
        warn "Aborted by user"
        subline
        info "Run summary: $CLEANED cleaned, $SKIPPED skipped, $EMPTY empty"
        subline
        exit 0
    fi

    if [ "$rc" -eq 0 ]; then
        for DIR in "${PATHS_ARRAY[@]}"; do
            if [ -d "$DIR" ]; then
                if rm -rf "$DIR" && mkdir -p "$DIR"; then
                    pass "Reset: $DIR"
                else
                    fail "Could not reset: $DIR"
                fi
            fi
        done
        CLEANED=$((CLEANED + 1))
    else
        skip "$APP_NAME skipped"
        SKIPPED=$((SKIPPED + 1))
    fi
}

# --- FUNCTION 2: DELETE DYNAMIC SUBFOLDERS (Remove Entirely) ---
clean_dynamic_root() {
    local LABEL=$1
    local ROOT_DIR=$2

    section "$LABEL"
    info "Scanning $ROOT_DIR"

    if [ ! -d "$ROOT_DIR" ]; then
        skip "Root folder not found"
        EMPTY=$((EMPTY + 1))
        return
    fi

    local count=0 DIR FOLDER_NAME SIZE rc
    shopt -s nullglob
    for DIR in "$ROOT_DIR"/*/; do
        count=$((count + 1))
        FOLDER_NAME=$(basename "$DIR")
        SIZE=$(du -sh "$DIR" 2>/dev/null | cut -f1)

        echo
        info "Project: $FOLDER_NAME (${SIZE:-?})"
        prompt_choice "  > DELETE '$FOLDER_NAME' entirely? [y/N, q=cancel all]"
        rc=$?
        if [ "$rc" -eq 2 ]; then
            warn "Aborted by user"
            subline
            info "Run summary: $CLEANED cleaned, $SKIPPED skipped, $EMPTY empty"
            subline
            shopt -u nullglob
            exit 0
        fi

        if [ "$rc" -eq 0 ]; then
            if rm -rf "$DIR"; then
                pass "Deleted: $FOLDER_NAME"
                CLEANED=$((CLEANED + 1))
            else
                fail "Could not delete: $FOLDER_NAME"
            fi
        else
            skip "Kept: $FOLDER_NAME"
            SKIPPED=$((SKIPPED + 1))
        fi
    done
    shopt -u nullglob

    if [ "$count" -eq 0 ]; then
        skip "No sub-folders in $LABEL"
        EMPTY=$((EMPTY + 1))
    fi
}

# --- MAIN EXECUTION ---
if declare -F play_logo_animation >/dev/null 2>&1; then
    play_logo_animation
fi

header "LOCAL CACHE CLEANUP"

# 1. Fixed App Paths
clean_defined_app "NUKE" NUKE_PATHS
clean_defined_app "MOCHA" MOCHA_PATHS
clean_defined_app "SYNTHEYES" SYNTHEYES_PATHS
clean_defined_app "DAVINCI RESOLVE" RESOLVE_PATHS
clean_defined_app "ADOBE MEDIA CACHE (AE/Premiere/ME/Audition shared)" ADOBE_MEDIA_CACHE_PATHS
clean_defined_app "AFTER EFFECTS" AE_PATHS
clean_defined_app "PREMIERE PRO" PREMIERE_PATHS

# 2. Dynamic Houdini Paths
clean_dynamic_root "HOUDINI RENDERS" "$HOUDINI_RENDER_ROOT"
clean_dynamic_root "HOUDINI SIMS"    "$HOUDINI_SIM_ROOT"

echo
subline
if [ "$CLEANED" -gt 0 ]; then
    pass "Cleaned: $CLEANED   Skipped: $SKIPPED   Empty: $EMPTY"
else
    info "Cleaned: $CLEANED   Skipped: $SKIPPED   Empty: $EMPTY"
fi
subline
read -r -p "Press Enter to exit..."
