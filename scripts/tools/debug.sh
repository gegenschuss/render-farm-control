#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#

show_help() {
    cat << 'EOF'
Usage: ./debug.sh [options]

Check if Windows update-related processes are active on a dual-boot node.
Target node is set via FARM_DEBUG_WIN_NODE in config/secrets.sh.

Options:
  -h, --help    Show this help message
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_help
    exit 0
fi

cd "$(dirname "$0")"
source ../lib/config.sh

WIN_NODE="${FARM_DEBUG_WIN_NODE:?Set FARM_DEBUG_WIN_NODE in config/secrets.sh}"

echo "Checking for active Windows updates on $WIN_NODE..."
echo ""

UPDATE_ACTIVE=$(ssh -F ~/.ssh/config -o ConnectTimeout=3 -o LogLevel=ERROR \
    $WIN_NODE \
    'powershell -Command "Get-Process -Name TiWorker,wuauclt,WUDFHost -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name"' \
    2>/dev/null)

echo "Raw output:"
echo "$UPDATE_ACTIVE"
echo ""

if echo "$UPDATE_ACTIVE" | grep -qi "TiWorker\|wuauclt\|WUDFHost"; then
    echo "RESULT: Windows update ACTIVE - would skip!"
else
    echo "RESULT: No active updates - safe to reboot"
fi