#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
# ============================================
#   farm - LOCAL SECRETS (TEMPLATE)
#   Copy this file to farm_secrets.sh and fill
#   in your values. farm_secrets.sh is excluded
#   from version control via .gitignore.
# ============================================

# --- Node Definitions ---
# Record format: NAME|MAC|BIOS_GUID|LINUX_WAIT|WIN_USER
# See farm_config.sh for field documentation.
FARM_NODE_DEFS=(
    # Linux-only nodes
    "node-01|AA:BB:CC:DD:EE:01|||"
    "node-02|AA:BB:CC:DD:EE:02|||"

    # Dual-boot nodes (with BIOS GUID for Linux boot entry)
    # "node-03|AA:BB:CC:DD:EE:03|{your-linux-boot-guid}|60|winuser"
)

# --- Linux Farm User ---
FARM_LINUX_HOME="/home/youruser"

# --- Deadline ---
FARM_DEADLINE_ALLOW_LIST="yourhost-gpu1"
# Install paths used by scripts/tools/install_app.sh (Deadline installer).
FARM_DEADLINE_PREFIX="/opt/Thinkbox/Deadline10"
FARM_DEADLINE_REPO_DIR="/mnt/DeadlineRepository10"

# --- Debug ---
# Default Windows dual-boot node for farm_debug.sh
FARM_DEBUG_WIN_NODE="node-03-win"

# --- Nuke Launcher ---
# Pixelmania plugin directories inside $FARM_LINUX_HOME/.nuke/pixelmania/
FARM_NUKE_PIXELMANIA_PLUGINS=(
    # "NNCleanup-v1.5.0_Nuke16.0_CUDA11.8_Linux"
)
FARM_OPTICAL_FLARES_LICENSE_PATH="/mnt/nuke/env/opticalFlares/Licenses/yourLicense"

# --- Path Mapping (used by Houdini submitters) ---
# Local Mac project root -> Linux farm mount prefix
FARM_LOCAL_PATH_PREFIX="/Users/youruser/YourProject/"
FARM_REMOTE_PATH_PREFIX="/mnt/"

# --- Wake Relay (optional) ---
# MAC of the workstation, woken by the relay host before farm nodes.
FARM_WORKSTATION_MAC="AA:BB:CC:DD:EE:FF"

# --- Installer Search Directories (farm_install_app.sh) ---
FARM_INSTALL_DIR_DEADLINE="/mnt/studio/install/deadline"
FARM_INSTALL_DIR_HOUDINI="/mnt/studio/install/houdini"

# --- Node Setup (setup_new_node.sh) ---
# Edit these before running setup on a new node.
SETUP_NODE_NAME="node-01"
SETUP_NODE_IP="192.168.x.x"
SETUP_STUDIO_USER="smbuser"
SETUP_STUDIO_PASS="changeme"
SETUP_DEADLINE_PASS="changeme"
SETUP_WORKSTATION_USER="rendering"
SETUP_WORKSTATION_PASS="changeme"
SETUP_NAS_IP="192.168.x.x"
SETUP_DEADLINE_IP="192.168.x.x"
SETUP_WORKSTATION_HOST="workstation"
SETUP_AUTOFS_MAP_NAME="auto.myfarm"
SETUP_SEARCH_DIR_HOUDINI="/mnt/studio/install/houdini"
SETUP_SEARCH_DIR_DEADLINE="/mnt/studio/install/deadline"
