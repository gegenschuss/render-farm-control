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
Usage: ./import_mocha.sh [options]

Import a Boris FX Mocha Pro Linux .rpm on THIS machine.

The system is checked first and decides the method:
  - rpm-based distro (Rocky/RHEL/Fedora): native install via dnf/rpm
  - apt-based distro (Ubuntu/Pop): extract the rpm (rpm2cpio/bsdtar)
    and overlay the payload onto /opt/BorisFX

Mocha's built-in updater saves new rpms into $HOME; manual downloads
land in ~/Downloads. Both are scanned automatically and the newest
rpm is offered for copy into $FARM_INSTALL_DIR_MOCHA, which is then
searched for the newest rpm to import.

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
farm_print_title "MOCHA PRO IMPORT"

SEARCH_DIR="${FARM_INSTALL_DIR_MOCHA:?Set FARM_INSTALL_DIR_MOCHA in config/secrets.sh}"
FILE_GLOB="*[Mm]ocha*.rpm"

# --- SYSTEM CHECK ---
farm_print_section "System check"

OS_ID="unknown" OS_VER="" OS_LIKE=""
if [ -r /etc/os-release ]; then
    OS_ID=$(. /etc/os-release; echo "${ID:-unknown}")
    OS_VER=$(. /etc/os-release; echo "${VERSION_ID:-}")
    OS_LIKE=$(. /etc/os-release; echo "${ID_LIKE:-}")
fi
echo "  os:         ${OS_ID} ${OS_VER}"

METHOD=""
case " $OS_ID $OS_LIKE " in
    *rocky*|*rhel*|*almalinux*|*centos*|*fedora*)
        if command -v dnf >/dev/null 2>&1; then
            METHOD="dnf"
        elif command -v rpm >/dev/null 2>&1; then
            METHOD="rpm"
        fi
        ;;
esac
if [ -z "$METHOD" ]; then
    if command -v rpm2cpio >/dev/null 2>&1 && command -v cpio >/dev/null 2>&1; then
        METHOD="extract"
    elif command -v bsdtar >/dev/null 2>&1; then
        METHOD="bsdtar"
    fi
fi

case "$METHOD" in
    dnf)     echo "  method:     native install (dnf)" ;;
    rpm)     echo "  method:     native install (rpm -Uvh)" ;;
    extract) echo "  method:     extract + overlay (rpm2cpio)" ;;
    bsdtar)  echo "  method:     extract + overlay (bsdtar)" ;;
    *)
        farm_print_error "No usable rpm tooling found on this system."
        echo "  Debian family: sudo apt install rpm2cpio cpio"
        echo "  RPM family:    dnf is expected to be present"
        exit 1
        ;;
esac

INSTALLED_DIR=$(ls -1d /opt/BorisFX/MochaPro* 2>/dev/null | sort -V | tail -n 1)
if [ -n "$INSTALLED_DIR" ]; then
    echo "  installed:  $(basename "$INSTALLED_DIR")"
else
    echo "  installed:  none found under /opt/BorisFX"
fi
echo ""

# --- AUTO-DETECT DOWNLOADED RPMS ---
# Mocha's built-in updater saves new rpms straight into $HOME;
# manual downloads usually land in ~/Downloads. Scan both, sorted
# by version in the basename (paths would sort wrong across dirs).
FOUND_RPM=$(for f in "$HOME"/$FILE_GLOB "$HOME/Downloads"/$FILE_GLOB; do
        [ -f "$f" ] && printf '%s\t%s\n' "$(basename "$f")" "$f"
    done | sort -V | tail -n 1 | cut -f2)

if [ -n "$FOUND_RPM" ] && [ ! -f "$SEARCH_DIR/$(basename "$FOUND_RPM")" ]; then
    echo "  Found downloaded rpm:"
    echo "    $(basename "$FOUND_RPM")"
    echo "    in $(dirname "$FOUND_RPM")"
    COPY_ARCHIVE="y"
    if [ "$AUTO_YES" -ne 1 ]; then
        farm_prompt_rule
        read -p "  Copy to install share? (y/n, q=cancel): " COPY_ARCHIVE
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
            cp "$FOUND_RPM" "$SEARCH_DIR/" || {
                farm_print_error "Copy failed."
                exit 1
            }
            farm_print_ok "Copied to install share."
        fi
    fi
    echo ""
fi

# --- PICK LATEST RPM ---
farm_print_section "Searching latest Mocha rpm"
echo "  Location:"
echo "  $SEARCH_DIR"
echo ""
if [ ! -d "$SEARCH_DIR" ]; then
    farm_print_error "Install directory not found: $SEARCH_DIR"
    echo "  Check that the network share is mounted."
    exit 1
fi
LATEST_RPM=$(ls -1 "$SEARCH_DIR"/$FILE_GLOB 2>/dev/null | sort -V | tail -n 1)
if [ -z "$LATEST_RPM" ] && [ "$DRY_RUN" -eq 1 ] && [ -n "$FOUND_RPM" ]; then
    # Dry-run never copies; report against the detected download.
    LATEST_RPM="$FOUND_RPM"
fi
if [ -z "$LATEST_RPM" ]; then
    farm_print_error "No matching .rpm found."
    exit 1
fi
FILENAME_ONLY=$(basename "$LATEST_RPM")
TARGET_VERSION=$(farm_extract_version "$FILENAME_ONLY")
echo "  Found:"
echo "    $FILENAME_ONLY"
echo "  Target version: ${TARGET_VERSION:-unknown}"
echo ""

if [ "$AUTO_YES" -ne 1 ]; then
    farm_prompt_rule
    read -p "  Import this rpm? (y/n): " PROCEED
    echo ""
    if [[ ! "$PROCEED" =~ ^[Yy]$ ]]; then
        echo "  Aborted."
        exit 0
    fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [dry-run] method: $METHOD"
    echo "  [dry-run] rpm:    $LATEST_RPM"
    farm_print_ok "Dry-run complete. No changes were made."
    exit 0
fi

# --- IMPORT ---
farm_print_section "Importing"
echo "  sudo may ask for your password."
echo ""
# Authenticate BEFORE any spinner starts: a sudo prompt under the
# spinner is erased by its line-redraw and waits invisibly forever.
farm_sudo_auth || { farm_print_error "sudo authentication failed."; exit 1; }
case "$METHOD" in
    dnf)
        sudo dnf install -y "$LATEST_RPM" 2>&1 | farm_indent
        RC=${PIPESTATUS[0]}
        ;;
    rpm)
        sudo rpm -Uvh --force "$LATEST_RPM" 2>&1 | farm_indent
        RC=${PIPESTATUS[0]}
        ;;
    extract|bsdtar)
        TMP_DIR=$(mktemp -d)
        trap 'rm -rf "$TMP_DIR"' EXIT
        farm_spin_start "extracting $FILENAME_ONLY"
        if [ "$METHOD" = "extract" ]; then
            ( cd "$TMP_DIR" && rpm2cpio "$LATEST_RPM" | cpio -idm --quiet )
        else
            ( cd "$TMP_DIR" && bsdtar -xf "$LATEST_RPM" )
        fi
        RC=$?
        farm_spin_stop
        if [ "$RC" -ne 0 ] || [ ! -d "$TMP_DIR/opt/BorisFX" ]; then
            farm_print_error "Extraction failed or no opt/BorisFX payload in rpm."
            exit 1
        fi
        echo "  Payload:"
        ls -1d "$TMP_DIR"/opt/BorisFX/*/ 2>/dev/null | while read -r d; do
            echo "    $(basename "$d")"
        done
        echo ""
        farm_spin_start "overlaying files onto /opt/BorisFX"
        sudo mkdir -p /opt/BorisFX && \
        sudo cp -a "$TMP_DIR/opt/BorisFX/." /opt/BorisFX/
        RC=$?
        # Desktop entries / icons, when the rpm ships them.
        if [ "$RC" -eq 0 ] && [ -d "$TMP_DIR/usr" ]; then
            sudo cp -a "$TMP_DIR/usr/." /usr/
            RC=$?
        fi
        farm_spin_stop
        ;;
esac

echo ""
farm_print_section "Verification"
# Newest version dir first (version-sorting full paths mis-orders
# "2026/bin" vs "2026.5/bin"), then its bin/ executable - a plain
# -name match would also catch .desktop files and icons.
NEW_DIR=$(ls -1d /opt/BorisFX/MochaPro* 2>/dev/null | sort -V | tail -n 1)
NEW_BIN=$(find "$NEW_DIR" -maxdepth 2 -path '*/bin/mochapro*' -type f 2>/dev/null \
    | head -n 1)
if [ "$RC" -eq 0 ] && [ -n "$NEW_BIN" ] && [ -x "$NEW_BIN" ]; then
    echo "  binary: $NEW_BIN"
    echo ""
    farm_print_summary "mocha ${TARGET_VERSION:-} imported (${METHOD})"
else
    farm_print_error "Import finished with problems (rc=$RC)."
    [ -z "$NEW_BIN" ] && echo "  No mochapro binary found under /opt/BorisFX."
    exit 1
fi
