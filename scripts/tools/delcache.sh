#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat << 'EOF'
Usage: sudo ./delcache.sh

Interactive cleanup for cache directories (Nuke/Mocha/SynthEyes/Resolve/Houdini).
EOF
  exit 0
fi

cd "$(dirname "$0")"
source ../lib/config.sh

"$FARM_SCRIPTS_DIR/lib/header.sh"
echo ""

# --- CONFIGURATION: FIXED PATHS ---
_HOME="${FARM_LINUX_HOME:-$HOME}"
declare -a NUKE_PATHS=("/mnt/nuke/cache/nuke" "$_HOME/.cache/nuke")
declare -a MOCHA_PATHS=("/mnt/nuke/cache/mocha" "$_HOME/.cache/mocha")
declare -a SYNTHEYES_PATHS=("/mnt/nuke/cache/syntheyes" "$_HOME/.cache/syntheyes")
declare -a RESOLVE_PATHS=("/mnt/nuke/cache/resolve" "/mnt/nuke/resolve/CacheClip" "$_HOME/.cache/resolve")

# --- CONFIGURATION: DYNAMIC PATHS ---
HOUDINI_RENDER_ROOT="/mnt/houdini/render"
HOUDINI_SIM_ROOT="/mnt/houdini/sim"

# --- SAFETY CHECK ---
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: Please run this script with sudo."
  exit 1
fi

# --- FUNCTION 1: CLEAN & RESET (Keep Folder) ---
clean_defined_app() {
    local APP_NAME=$1
    local -n PATHS_ARRAY=$2

    echo "Checking $APP_NAME..."
    
    local FOUND_ANY=false
    for DIR in "${PATHS_ARRAY[@]}"; do
        if [ -d "$DIR" ]; then
            SIZE=$(du -sh "$DIR" 2>/dev/null | cut -f1)
            echo "   Found: $DIR ($SIZE)"
            FOUND_ANY=true
        fi
    done

    if [ "$FOUND_ANY" = false ]; then
        echo "   (No directories found to clean)"
        echo " "
        echo " "
        return
    fi

    read -p "Purge contents of $APP_NAME? (y/n, q=cancel) " -n 1 -r
    echo "" 
    if [[ $REPLY =~ ^[Qq]$ ]]; then
        echo "   Aborted."
        echo " "
        echo " "
        exit 0
    fi

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "   Emptying $APP_NAME..."
        for DIR in "${PATHS_ARRAY[@]}"; do
            if [ -d "$DIR" ]; then
                rm -rf "$DIR"
                mkdir -p "$DIR"
                chmod 777 "$DIR"
                echo "      reset: $DIR"
            fi
        done
        echo "   Contents cleared."
        echo " "
        echo " "
    else
        echo "   Skipped"
        echo " "
        echo " "
    fi
}

# --- FUNCTION 2: DELETE DYNAMIC SUBFOLDERS (Remove Entirely) ---
clean_dynamic_root() {
    local LABEL=$1
    local ROOT_DIR=$2

    echo "Scanning $LABEL ($ROOT_DIR)..."

    if [ ! -d "$ROOT_DIR" ]; then
        echo "Root folder not found."
        return
    fi

    local count=0
    # Use nullglob so empty folders don't break the loop
    shopt -s nullglob
    for DIR in "$ROOT_DIR"/*/; do
        count=$((count+1))
        FOLDER_NAME=$(basename "$DIR")
        SIZE=$(du -sh "$DIR" 2>/dev/null | cut -f1)

        echo ""
        echo "   Found Project: $FOLDER_NAME ($SIZE)"
        read -p "   > DELETE '$FOLDER_NAME' entirely? (y/n, q=cancel) " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Qq]$ ]]; then
            echo "      Aborted."
            echo " "
            echo " "
            exit 0
        fi

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$DIR"
            echo "      $FOLDER_NAME deleted."
            echo " "
            echo " "
        else
            echo "      Skipped."
            echo " "
            echo " "
        fi
    done
    shopt -u nullglob

    if [ "$count" -eq 0 ]; then
        echo "   (No sub-folders found in $LABEL)"
        echo " "
        echo " "
    fi
}

# --- MAIN EXECUTION ---

# 1. Fixed App Paths
clean_defined_app "NUKE" NUKE_PATHS
clean_defined_app "MOCHA" MOCHA_PATHS
clean_defined_app "SYNTHEYES" SYNTHEYES_PATHS
clean_defined_app "DAVINCI RESOLVE" RESOLVE_PATHS

# 2. Dynamic Houdini Paths
clean_dynamic_root "HOUDINI RENDERS" "$HOUDINI_RENDER_ROOT"
clean_dynamic_root "HOUDINI SIMS" "$HOUDINI_SIM_ROOT"

echo "------------------------------------------"
echo "Done."