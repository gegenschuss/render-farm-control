#!/bin/bash
#  _____                         _
# |   __|___ ___ ___ ___ ___ ___| |_ _ _ ___ ___
# |  |  | -_| . | -_|   |_ -|  _|   | | |_ -|_ -|
# |_____|___|_  |___|_|_|___|___|_|_|___|___|___|
#           |___|
#
# Cache cleanup — default user cache paths for common VFX / Adobe apps.
# macOS covers Nuke, Mocha, SynthEyes, Resolve and the Adobe caches;
# Linux covers Nuke, Resolve and the Houdini roots.

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat << 'EOF'
Usage: ./delcache.sh

Interactive cleanup for app cache directories.
Apps covered:
  - Nuke, DaVinci Resolve (macOS + Linux)
  - Mocha, SynthEyes (macOS)
  - Adobe shared Media Cache (AE / Premiere / Media Encoder / Audition) (macOS)
  - After Effects, Premiere Pro (macOS)
  - Houdini render/sim project roots (via $HOUDINI_RENDER_ROOT / $HOUDINI_SIM_ROOT)

Override Houdini roots:
  HOUDINI_RENDER_ROOT=/Volumes/work/houdini/render ./delcache.sh
EOF
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/ui.sh"

prompt_choice() {
  local question="$1"
  printf '  %b%s%b ' "${C_BOLD}" "$question" "$C_RESET"
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
# nullglob so version-numbered folders expand cleanly, and missing
# patterns drop out instead of becoming literal strings.
shopt -s nullglob

if [ "$UI_OS" = "mac" ]; then
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
else
    # Nuke on Linux — viewer cache plus the default disk-cache temp dirs
    declare -a NUKE_PATHS=(
        "$HOME/.nuke/ViewerCache"
        /var/tmp/nuke-u*
    )

    # DaVinci Resolve on Linux
    declare -a RESOLVE_PATHS=(
        "$HOME/.local/share/DaVinciResolve/CacheClip"
        "$HOME/.local/share/DaVinciResolve/GalleryStills"
    )
fi

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

print_run_summary() {
    echo
    ui_summary "$CLEANED cleaned ${UI_G_SEP} $SKIPPED skipped ${UI_G_SEP} $EMPTY empty"
}

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
        print_run_summary
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
            print_run_summary
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
ui_play_logo
header "LOCAL CACHE CLEANUP"

# 1. Fixed App Paths
clean_defined_app "NUKE" NUKE_PATHS
clean_defined_app "DAVINCI RESOLVE" RESOLVE_PATHS
if [ "$UI_OS" = "mac" ]; then
    clean_defined_app "MOCHA" MOCHA_PATHS
    clean_defined_app "SYNTHEYES" SYNTHEYES_PATHS
    clean_defined_app "ADOBE SHARED MEDIA CACHE" ADOBE_MEDIA_CACHE_PATHS
    clean_defined_app "AFTER EFFECTS" AE_PATHS
    clean_defined_app "PREMIERE PRO" PREMIERE_PATHS
fi

# 2. Dynamic Houdini Paths
clean_dynamic_root "HOUDINI RENDERS" "$HOUDINI_RENDER_ROOT"
clean_dynamic_root "HOUDINI SIMS"    "$HOUDINI_SIM_ROOT"

print_run_summary
ui_wait_exit
