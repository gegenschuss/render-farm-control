#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
# ============================================
#   remote menu - LOCAL SECRETS (TEMPLATE)
#   Copy this file to secrets.sh and fill
#   in your values. secrets.sh is excluded
#   from version control via .gitignore.
# ============================================

# --- Deadline Server ---
DEADLINE_USER="deadline"
DEADLINE_HOST="100.x.x.x"
DEADLINE_SHARE="DeadlineRepository10"

# --- NAS / File Server ---
NAS_USER="youruser"
NAS_HOST="100.x.x.x"
NAS_STUDIO_SHARE="studio"
NAS_BUERO_SHARE="buero"

# --- Workstation ---
WORKSTATION_USER="youruser"
WORKSTATION_HOST="100.x.x.x"
WORKSTATION_HOUDINI_SHARE="houdini"
WORKSTATION_NUKE_SHARE="nuke"
WORKSTATION_SSH_HOST="workstation"

# --- Wake Relay ---
# Host that runs Wake-on-LAN commands for the farm
WAKE_RELAY_HOST="wake-relay"
WAKE_RELAY_SCRIPT="./.wake.sh"

# --- Remote Farm Script Paths (on the workstation) ---
FARM_SCRIPT_PATH="/mnt/studio/Toolbox/farm/farm.sh"
FARM_SHUTDOWN_SCRIPT_PATH="/mnt/studio/Toolbox/farm/farm_shutdown.sh"

# --- Ping Status Nodes (name|tailscale_ip) ---
PING_NODES=(
    "workstation|100.x.x.x"
    "node-01|100.x.x.x"
    "node-02|100.x.x.x"
)

# --- SMB Shares (for unmount script) ---
SMB_SHARES=(
    "DeadlineRepository10"
    "studio"
    "buero"
    "houdini"
    "nuke"
)
