#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat << 'EOF'
Usage: ./launch_houdini.sh

Launch Houdini using the configured HFS path.
EOF
    exit 0
fi

# Find the latest installed Houdini version
HFS=$(printf '%s\n' /opt/hfs* 2>/dev/null | sort -V | tail -n 1)

# Check if the directory exists before proceeding
if [ -d "$HFS" ]; then
    echo "Found Houdini at $HFS. Sourcing environment..."
    
    # Move into the directory and source the setup script
    cd "$HFS"
    source ./houdini_setup
    
    # Launch Houdini in the background
    # Use 'houdini -foreground' if you want to see console logs in this terminal
    houdini -foreground
else
    echo "Error: Houdini directory not found at $HFS"
    exit 1
fi