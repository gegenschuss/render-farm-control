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
Usage: ./update_blender.sh [options]

Update Blender in /opt/blender on THIS machine only (Blender is not
used on the render nodes).

The newest stable release is looked up on download.blender.org and
downloaded into $FARM_INSTALL_DIR_BLENDER (sha256-verified). When
offline, the newest blender-*-linux-x64.tar.xz already in that share
is used instead (or copied there from a download directory). The
install is a staged swap, so a failed extract never replaces a
working /opt/blender.

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
farm_print_title "BLENDER UPDATE (LOCAL)"

SEARCH_DIR="${FARM_INSTALL_DIR_BLENDER:?Set FARM_INSTALL_DIR_BLENDER in config/secrets.sh}"
FILE_GLOB="blender-*-linux-x64.tar.xz"

# --- CURRENT STATE ---
farm_print_section "System check"
INSTALLED_RAW=$(/opt/blender/blender --version 2>/dev/null | head -n 1)
INSTALLED_VER=$(farm_extract_version "$INSTALLED_RAW")
if [ -n "$INSTALLED_VER" ]; then
    echo "  installed:  $INSTALLED_VER  (/opt/blender)"
else
    echo "  installed:  none found at /opt/blender"
fi
echo ""

# --- ONLINE CHECK (download.blender.org) ---
farm_print_section "Checking blender.org"
RELEASE_URL="https://download.blender.org/release"
SERIES="" REMOTE_FILE=""
farm_spin_start "looking up newest release"
SERIES=$(curl -fsSL --connect-timeout 8 "$RELEASE_URL/" 2>/dev/null \
    | grep -oE 'Blender[0-9]+\.[0-9]+' | sort -uV | tail -n 1)
if [ -n "$SERIES" ]; then
    REMOTE_FILE=$(curl -fsSL --connect-timeout 8 "$RELEASE_URL/$SERIES/" 2>/dev/null \
        | grep -oE 'blender-[0-9]+\.[0-9]+\.[0-9]+-linux-x64\.tar\.xz' \
        | sort -uV | tail -n 1)
fi
farm_spin_stop

if [ -z "$REMOTE_FILE" ]; then
    farm_print_warn "blender.org not reachable - using local archives."
    echo ""
    # Offline fallback: offer to copy a manually downloaded archive.
    if [ "$AUTO_YES" -ne 1 ]; then
        echo "  Copy a new archive to the install share first?"
        echo "  $SEARCH_DIR"
        farm_prompt_rule
        read -p "  (y/N, q=cancel): " COPY_ARCHIVE
        echo ""
        if [[ "$COPY_ARCHIVE" == "q" || "$COPY_ARCHIVE" == "Q" ]]; then
            echo "  Aborted."
            exit 0
        fi
        if [[ "$COPY_ARCHIVE" =~ ^[Yy]$ ]]; then
            read -p "  Copy from (default: ~/Downloads): " COPY_SOURCE
            if [[ "$COPY_SOURCE" == "q" || "$COPY_SOURCE" == "Q" ]]; then
                echo "  Aborted."
                exit 0
            fi
            COPY_SOURCE="${COPY_SOURCE:-$HOME/Downloads}"
            COPY_SOURCE="${COPY_SOURCE/#\~/$HOME}"
            COPY_TAR=$(ls -1 "$COPY_SOURCE"/$FILE_GLOB 2>/dev/null | sort -V | tail -n 1)
            if [ -z "$COPY_TAR" ]; then
                farm_print_error "No blender archive found in: $COPY_SOURCE"
                exit 1
            fi
            echo "  Found: $(basename "$COPY_TAR")"
            cp "$COPY_TAR" "$SEARCH_DIR/" || {
                farm_print_error "Copy failed."
                exit 1
            }
            farm_print_ok "Copied to install share."
            echo ""
        fi
    fi
else
    REMOTE_VER=$(farm_extract_version "$REMOTE_FILE")
    echo "  newest:     ${REMOTE_VER}"
    if [ -f "$SEARCH_DIR/$REMOTE_FILE" ]; then
        echo "  archive:    already in install share"
        echo ""
    elif [ "$(farm_install_classify "$INSTALLED_VER" "$REMOTE_VER")" = "uptodate" ]; then
        echo ""
        farm_print_summary "already up to date (${INSTALLED_VER})"
        exit 0
    else
        FETCH="y"
        if [ "$AUTO_YES" -ne 1 ]; then
            farm_prompt_rule
            read -p "  Download ${REMOTE_VER} now? (y/N, q=cancel): " FETCH
            echo ""
            if [[ "$FETCH" == "q" || "$FETCH" == "Q" ]]; then
                echo "  Aborted."
                exit 0
            fi
        fi
        if [[ "$FETCH" =~ ^[Yy]$ ]]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "  [dry-run] download: $RELEASE_URL/$SERIES/$REMOTE_FILE"
                if [ ! -f "$SEARCH_DIR/$REMOTE_FILE" ]; then
                    echo "  [dry-run] staged swap of /opt/blender"
                    echo ""
                    farm_print_ok "Dry-run complete. No changes were made."
                    exit 0
                fi
                echo ""
            else
                mkdir -p "$SEARCH_DIR" 2>/dev/null
                if [ ! -d "$SEARCH_DIR" ]; then
                    farm_print_error "Install directory not found: $SEARCH_DIR"
                    echo "  Check that the network share is mounted."
                    exit 1
                fi
                CURL_PROGRESS='-#'
                [ -t 1 ] || CURL_PROGRESS='-s'
                echo "  downloading ${REMOTE_FILE}"
                if ! curl -fL --connect-timeout 8 $CURL_PROGRESS \
                    -o "$SEARCH_DIR/$REMOTE_FILE.part" \
                    "$RELEASE_URL/$SERIES/$REMOTE_FILE"; then
                    rm -f "$SEARCH_DIR/$REMOTE_FILE.part"
                    farm_print_error "Download failed."
                    exit 1
                fi
                # Verify against the release's published sha256 list.
                farm_spin_start "verifying sha256"
                EXPECTED_SUM=$(curl -fsSL --connect-timeout 8 \
                    "$RELEASE_URL/$SERIES/blender-${REMOTE_VER}.sha256" 2>/dev/null \
                    | grep "$REMOTE_FILE" | awk '{print $1}')
                ACTUAL_SUM=$(sha256sum "$SEARCH_DIR/$REMOTE_FILE.part" | awk '{print $1}')
                farm_spin_stop
                if [ -z "$EXPECTED_SUM" ]; then
                    farm_print_warn "No published checksum found - skipping verify."
                elif [ "$EXPECTED_SUM" != "$ACTUAL_SUM" ]; then
                    rm -f "$SEARCH_DIR/$REMOTE_FILE.part"
                    farm_print_error "Checksum mismatch - download discarded."
                    exit 1
                fi
                mv "$SEARCH_DIR/$REMOTE_FILE.part" "$SEARCH_DIR/$REMOTE_FILE"
                farm_print_ok "Downloaded and verified."
                echo ""
            fi
        fi
    fi
fi

# --- PICK LATEST ARCHIVE ---
farm_print_section "Searching latest Blender archive"
echo "  Location:"
echo "  $SEARCH_DIR"
echo ""
if [ ! -d "$SEARCH_DIR" ]; then
    farm_print_error "Install directory not found: $SEARCH_DIR"
    echo "  Check that the network share is mounted."
    exit 1
fi
LATEST_TAR=$(ls -1 "$SEARCH_DIR"/$FILE_GLOB 2>/dev/null | sort -V | tail -n 1)
if [ -z "$LATEST_TAR" ]; then
    farm_print_error "No matching archive found."
    exit 1
fi
FILENAME_ONLY=$(basename "$LATEST_TAR")
TARGET_VERSION=$(farm_install_target_version "$FILENAME_ONLY")
STATE=$(farm_install_classify "$INSTALLED_VER" "$TARGET_VERSION")
echo "  Found:"
echo "    $FILENAME_ONLY"
case "$STATE" in
    uptodate)
        echo -e "  Status: ${FARM_C_OK}already up to date (${INSTALLED_VER})${FARM_C_RESET}" ;;
    update)
        echo -e "  Status: ${FARM_C_WARN}update ${INSTALLED_VER} -> ${TARGET_VERSION}${FARM_C_RESET}" ;;
    notinstalled)
        echo -e "  Status: ${FARM_C_WARN}fresh install -> ${TARGET_VERSION}${FARM_C_RESET}" ;;
    *)
        echo "  Status: unknown target version" ;;
esac
echo ""

if [ "$STATE" = "uptodate" ] && [ "$AUTO_YES" -eq 1 ]; then
    farm_print_ok "Nothing to do."
    exit 0
fi

if [ "$AUTO_YES" -ne 1 ]; then
    farm_prompt_rule
    read -p "  Update /opt/blender? (y/N): " PROCEED
    echo ""
    if [[ ! "$PROCEED" =~ ^[Yy]$ ]]; then
        echo "  Aborted."
        exit 0
    fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [dry-run] archive: $LATEST_TAR"
    echo "  [dry-run] staged swap of /opt/blender"
    farm_print_ok "Dry-run complete. No changes were made."
    exit 0
fi

# --- STAGED SWAP ---
farm_print_section "Updating /opt/blender"
echo "  sudo may ask for your password."
echo ""
# Authenticate before the spinner (a prompt under it is invisible).
farm_sudo_auth || { farm_print_error "sudo authentication failed."; exit 1; }
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

farm_spin_start "extracting $FILENAME_ONLY"
tar -xf "$LATEST_TAR" -C "$TMP_DIR"
RC=$?
farm_spin_stop
NEW_DIR=$(find "$TMP_DIR" -maxdepth 1 -type d -name 'blender-*' | head -n 1)
if [ "$RC" -ne 0 ] || [ -z "$NEW_DIR" ] || [ ! -x "$NEW_DIR/blender" ]; then
    farm_print_error "Extraction failed or archive layout unexpected."
    exit 1
fi

# Swap only after a complete extract, so /opt/blender is never half-new.
sudo rm -rf /opt/blender.new /opt/blender.old && \
sudo mv "$NEW_DIR" /opt/blender.new && \
{ [ ! -d /opt/blender ] || sudo mv /opt/blender /opt/blender.old; } && \
sudo mv /opt/blender.new /opt/blender && \
sudo rm -rf /opt/blender.old
RC=$?

echo ""
farm_print_section "Verification"
NEW_RAW=$(/opt/blender/blender --version 2>/dev/null | head -n 1)
NEW_VER=$(farm_extract_version "$NEW_RAW")
if [ "$RC" -eq 0 ] && [ -n "$NEW_VER" ]; then
    echo "  $NEW_RAW"
    echo ""
    farm_print_summary "blender ${NEW_VER} installed"
else
    farm_print_error "Update finished with problems (rc=$RC)."
    [ -d /opt/blender.old ] && echo "  Previous install kept at /opt/blender.old"
    exit 1
fi
