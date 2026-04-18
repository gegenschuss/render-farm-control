#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat << 'EOF'
Usage: ./launch_nuke.sh [nuke-args...]

Launch latest installed Nuke in Indie mode.
Any additional arguments are passed through to Nuke.
EOF
    exit 0
fi

# 1. Load secrets and define environment variables
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/secrets.sh"

# Build NUKE_PATH from shared env and user-specific plugin directories.
NUKE_PATH="/mnt/nuke/env/gizmos;/mnt/nuke/env/icons;/mnt/nuke/env/lut;/mnt/nuke/env/mo;/mnt/nuke/env/python;/mnt/nuke/env/plugins;/mnt/nuke/env/tcl;/mnt/nuke/env/nuke"
for _plugin in "${FARM_NUKE_PIXELMANIA_PLUGINS[@]}"; do
    NUKE_PATH="$NUKE_PATH;$FARM_LINUX_HOME/.nuke/pixelmania/$_plugin/"
done
NUKE_PATH="$NUKE_PATH;$FARM_LINUX_HOME/.nuke/furytools;/mnt/nuke/env/NukeSurvivalToolkit;/mnt/nuke/env/;"
export NUKE_PATH

export OPTICAL_FLARES_LICENSE_PATH="$FARM_OPTICAL_FLARES_LICENSE_PATH"
export OPTICAL_FLARES_PRESET_PATH="/mnt/nuke/env/opticalFlares/Lens Flares"
export OPTICAL_FLARES_PREFERENCE_PATH="/mnt/nuke/env/opticalFlares"
export OPTICAL_FLARES_PATH="/mnt/nuke/env/opticalFlares"
export NKPD_REPO_PATH="/mnt/nuke/env/nukepedia"

export NUKE_TEMP_DIR="$FARM_LINUX_HOME/.cache/nuke/"


# 2. Find the newest Nuke installation in /opt
# This looks for directories matching Nuke* (e.g., /opt/Nuke16.0v1)
LATEST_INSTALL=$(printf '%s\n' /opt/Nuke* 2>/dev/null | sort -V | tail -n 1)

if [ -z "$LATEST_INSTALL" ]; then
    echo "Error: No Nuke installation found in /opt"
    exit 1
fi

# 3. Resolve the binary name
FOLDER_NAME=$(basename "$LATEST_INSTALL")
BINARY_NAME=$(echo "$FOLDER_NAME" | cut -d 'v' -f 1)
NUKE_BINARY_PATH="$LATEST_INSTALL/$BINARY_NAME"

# 4. Launch Nuke in Indie Mode
if [ -f "$NUKE_BINARY_PATH" ]; then
    echo "Launching $BINARY_NAME Indie from $LATEST_INSTALL..."
    "$NUKE_BINARY_PATH" --indie "$@" &
else
    echo "Error: Binary not found at $NUKE_BINARY_PATH"
    echo "Check if the binary name matches the folder name prefix."
    exit 1
fi