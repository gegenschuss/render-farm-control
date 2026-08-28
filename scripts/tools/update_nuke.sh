#!/bin/bash
#  _____                         _
# |   __|___ ___ ___ ___ ___ ___| |_ _ _ ___ ___
# |  |  | -_| . | -_|   |_ -|  _|   | | |_ -|_ -|
# |_____|___|_  |___|_|_|___|___|_|_|___|___|___|
#           |___|
#
cd "$(dirname "$0")"
source ../lib/config.sh
source ../lib/install_lib.sh

show_help() {
    cat << 'EOF'
Usage: ./update_nuke.sh [options]

Install a new Nuke version to /opt on THIS machine only (Nuke is
not used on the render nodes). Existing /opt/Nuke* versions are
kept untouched (parallel installs).

Foundry downloads require a browser login, so there is no online
check or auto-download: download the Nuke*-linux-x86_64.tgz in
the browser; it is found in ~/Downloads (or $HOME) automatically
and copied into $FARM_INSTALL_DIR_NUKE. The bundled installer is
then run with --accept-foundry-eula --prefix=/opt.

Options:
  -h, --help      Show this help message
  -y, --yes       Auto-confirm prompts
      --dry-run   Print planned actions without executing
EOF
}

AUTO_YES=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        -h|--help) show_help; exit 0 ;;
        -y|--yes) AUTO_YES=1 ;;
        --dry-run) DRY_RUN=1 ;;
        *) farm_die_unknown_option "$arg" show_help ;;
    esac
done

"$FARM_SCRIPTS_DIR/lib/header.sh"
farm_print_title "NUKE UPDATE (LOCAL)"

SEARCH_DIR="${FARM_INSTALL_DIR_NUKE:?Set FARM_INSTALL_DIR_NUKE in config/secrets.sh}"
FILE_GLOB="Nuke*-linux-x86_64.tgz"

# --- CURRENT STATE ---
farm_print_section "System check"
INSTALLED_NAME=$(ls -1d /opt/Nuke*/ 2>/dev/null | sed 's|/$||;s|.*/||' \
    | sort -V | tail -n 1)
if [ -n "$INSTALLED_NAME" ]; then
    echo "  installed:  $INSTALLED_NAME  (/opt)"
else
    echo "  installed:  none found in /opt"
fi
echo -e "  ${FARM_C_DIM}online check unavailable (Foundry login required)${FARM_C_RESET}"
echo ""

# --- AUTO-DETECT DOWNLOADED ARCHIVES ---
# Browser downloads land in ~/Downloads (or $HOME); newest by the
# version in the basename (paths would sort wrong across dirs).
FOUND_TGZ=$(for f in "$HOME"/$FILE_GLOB "$HOME/Downloads"/$FILE_GLOB; do
        [ -f "$f" ] && printf '%s\t%s\n' "$(basename "$f")" "$f"
    done | sort -V | tail -n 1 | cut -f2)

if [ -n "$FOUND_TGZ" ] && [ ! -f "$SEARCH_DIR/$(basename "$FOUND_TGZ")" ]; then
    echo "  Found downloaded archive:"
    echo "    $(basename "$FOUND_TGZ")"
    echo "    in $(dirname "$FOUND_TGZ")"
    COPY_ARCHIVE="y"
    if [ "$AUTO_YES" -ne 1 ]; then
        farm_prompt_rule
        read -p "  Copy to install share? (y/N, q=cancel): " COPY_ARCHIVE
        echo ""
        if [[ "$COPY_ARCHIVE" == "q" || "$COPY_ARCHIVE" == "Q" ]]; then
            echo "  Aborted."
            exit 0
        fi
    fi
    if [[ "$COPY_ARCHIVE" =~ ^[Yy]$ ]]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "  [dry-run] would copy to install share."
        else
            mkdir -p "$SEARCH_DIR" 2>/dev/null
            cp "$FOUND_TGZ" "$SEARCH_DIR/" || {
                farm_print_error "Copy failed."
                exit 1
            }
            farm_print_ok "Copied to install share."
        fi
    fi
    echo ""
fi

# --- PICK LATEST ARCHIVE ---
farm_print_section "Searching latest Nuke archive"
echo "  Location:"
echo "  $SEARCH_DIR"
echo ""
LATEST_TGZ=$(ls -1 "$SEARCH_DIR"/$FILE_GLOB 2>/dev/null | sort -V | tail -n 1)
if [ "$DRY_RUN" -eq 1 ] && [ -n "$FOUND_TGZ" ] && [[ "${COPY_ARCHIVE:-y}" =~ ^[Yy]$ ]]; then
    # Dry-run never copies; report against the detected download when
    # a real run would have copied it and it is the newer archive.
    if [ -z "$LATEST_TGZ" ] || [ "$(printf '%s\n%s\n' \
        "$(basename "$LATEST_TGZ")" "$(basename "$FOUND_TGZ")" \
        | sort -V | tail -n 1)" = "$(basename "$FOUND_TGZ")" ]; then
        LATEST_TGZ="$FOUND_TGZ"
    fi
fi
if [ -z "$LATEST_TGZ" ]; then
    farm_print_error "No matching archive found."
    echo "  Download the Linux tgz in the browser first (login):"
    echo "  https://www.foundry.com/products/nuke/download"
    exit 1
fi
FILENAME_ONLY=$(basename "$LATEST_TGZ")
TARGET_NAME="${FILENAME_ONLY%-linux-x86_64.tgz}"
echo "  Found:"
echo "    $FILENAME_ONLY"
NEWEST_OF_BOTH=$(printf '%s\n%s\n' "$TARGET_NAME" "$INSTALLED_NAME" | sort -V | tail -n 1)
if [ -d "/opt/$TARGET_NAME" ]; then
    echo -e "  Status: ${FARM_C_OK}already installed (${TARGET_NAME})${FARM_C_RESET}"
    STATE="uptodate"
elif [ -z "$INSTALLED_NAME" ]; then
    echo -e "  Status: ${FARM_C_WARN}fresh install -> ${TARGET_NAME}${FARM_C_RESET}"
    STATE="notinstalled"
elif [ "$NEWEST_OF_BOTH" = "$TARGET_NAME" ]; then
    echo -e "  Status: ${FARM_C_WARN}update ${INSTALLED_NAME} -> ${TARGET_NAME}${FARM_C_RESET}"
    STATE="update"
else
    echo -e "  Status: ${FARM_C_DIM}older than installed (${INSTALLED_NAME}) - parallel install${FARM_C_RESET}"
    STATE="update"
fi
echo ""

if [ "$STATE" = "uptodate" ] && [ "$AUTO_YES" -eq 1 ]; then
    farm_print_ok "Nothing to do."
    exit 0
fi

if [ "$AUTO_YES" -ne 1 ]; then
    farm_prompt_rule
    read -p "  Install to /opt/${TARGET_NAME}? (y/N): " PROCEED
    echo ""
    if [[ ! "$PROCEED" =~ ^[Yy]$ ]]; then
        echo "  Aborted."
        exit 0
    fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [dry-run] extract: $LATEST_TGZ"
    echo "  [dry-run] sudo <installer>.run --accept-foundry-eula --prefix=/opt"
    farm_print_ok "Dry-run complete. No changes were made."
    exit 0
fi

# --- EXTRACT + INSTALL ---
farm_print_section "Installing"
echo "  sudo may ask for your password."
echo ""
# Authenticate before the spinner (a prompt under it is invisible).
farm_sudo_auth || { farm_print_error "sudo authentication failed."; exit 1; }
# /var/tmp: disk-backed (the installer is several GB and /tmp may be
# tmpfs/RAM).
TMP_DIR=$(mktemp -d /var/tmp/nuke_update.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

farm_spin_start "extracting $FILENAME_ONLY"
tar -xzf "$LATEST_TGZ" -C "$TMP_DIR"
RC=$?
farm_spin_stop
RUN_FILE=$(find "$TMP_DIR" -maxdepth 1 -name 'Nuke*-linux-x86_64.run' | head -n 1)
if [ "$RC" -ne 0 ] || [ -z "$RUN_FILE" ]; then
    farm_print_error "Extraction failed or no .run installer in the tgz."
    exit 1
fi
chmod +x "$RUN_FILE"

echo "  running $(basename "$RUN_FILE")"
echo ""
sudo "$RUN_FILE" --accept-foundry-eula --prefix=/opt 2>&1 | farm_indent
RC=${PIPESTATUS[0]}

echo ""
farm_print_section "Verification"
NEW_BIN=$(find "/opt/$TARGET_NAME" -maxdepth 1 -name 'Nuke*' -type f \
    -perm -u+x 2>/dev/null | head -n 1)
if [ "$RC" -eq 0 ] && [ -n "$NEW_BIN" ]; then
    echo "  binary: $NEW_BIN"
    echo -e "  ${FARM_C_DIM}older /opt/Nuke* versions were kept${FARM_C_RESET}"
    echo ""
    farm_print_summary "${TARGET_NAME,,} installed"
else
    farm_print_error "Install finished with problems (rc=$RC)."
    exit 1
fi
