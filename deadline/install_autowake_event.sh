#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
cd "$(dirname "$0")"
source ../scripts/lib/config.sh
farm_require_bash4 "install_autowake_event.sh"

show_help() {
    cat << 'EOF'
Usage: ./install_autowake_event.sh [options]

Install the FarmAutoWake Deadline event plugin into:
  $FARM_DEADLINE_REPO_DIR/custom/events/FarmAutoWake

Options:
  -h, --help      Show this help message
      --dry-run   Print copy actions without writing files
EOF
}

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            show_help
            exit 0
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        *)
            farm_die_unknown_option "$arg" show_help
            ;;
    esac
done

SRC_DIR="$FARM_BASE_DIR/deadline"
DST_DIR="$FARM_DEADLINE_REPO_DIR/custom/events/FarmAutoWake"

if [ ! -d "$SRC_DIR" ]; then
    farm_print_error "Source plugin directory not found: $SRC_DIR"
    exit 1
fi

farm_print_title "INSTALL DEADLINE EVENT: FARMAUTOWAKE"
echo "Source: $SRC_DIR"
echo "Target: $DST_DIR"
echo ""

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] mkdir -p \"$DST_DIR\""
    echo "[dry-run] cp \"$SRC_DIR/FarmAutoWake.py\" \"$DST_DIR/FarmAutoWake.py\""
    echo "[dry-run] cp \"$SRC_DIR/FarmAutoWake.param\" \"$DST_DIR/FarmAutoWake.param\""
    echo ""
    farm_print_ok "Dry-run complete."
    exit 0
fi

mkdir -p "$DST_DIR"
cp "$SRC_DIR/FarmAutoWake.py" "$DST_DIR/FarmAutoWake.py"
cp "$SRC_DIR/FarmAutoWake.param" "$DST_DIR/FarmAutoWake.param"

farm_print_ok "Installed FarmAutoWake event plugin."
echo "Next: open Deadline Monitor -> Tools -> Configure Events -> FarmAutoWake."
