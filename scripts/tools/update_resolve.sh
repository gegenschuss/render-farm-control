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
Usage: ./update_resolve.sh [options]

Update DaVinci Resolve in /opt/resolve on THIS machine only,
following the flolu/davinci-resolve-linux workflow (unzip the
official DaVinci_Resolve_*_Linux.zip, run the .run installer).

The newest stable version is looked up on blackmagicdesign.com
and downloaded automatically via the "Download Only" path (no
registration data is sent). Edition defaults to Studio; set
FARM_RESOLVE_EDITION=free in config/secrets.sh for the free
version. A manually downloaded zip in ~/Downloads (or $HOME) is
also found automatically and copied into
$FARM_INSTALL_DIR_RESOLVE.

The install follows the makeresolvedeb workflow this machine
already uses (dpkg shows davinci-resolve-studio *-mrdX.Y.Z): the
newest makeresolvedeb script is fetched from danieltufvesson.com,
builds a .deb from the .run installer, and the .deb is installed
with dpkg -i - so the package stays apt-managed.

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
farm_print_title "RESOLVE UPDATE (LOCAL)"

SEARCH_DIR="${FARM_INSTALL_DIR_RESOLVE:?Set FARM_INSTALL_DIR_RESOLVE in config/secrets.sh}"
FILE_GLOB="DaVinci_Resolve_*Linux.zip"

# --- CURRENT STATE ---
farm_print_section "System check"
# dpkg is authoritative (makeresolvedeb installs), Welcome.txt the
# fallback for a .run-installed Resolve.
INSTALLED_VER=$(dpkg-query -W -f '${Version}' davinci-resolve-studio 2>/dev/null \
    | sed 's/-mrd.*//')
[ -z "$INSTALLED_VER" ] && INSTALLED_VER=$(dpkg-query -W -f '${Version}' \
    davinci-resolve 2>/dev/null | sed 's/-mrd.*//')
[ -z "$INSTALLED_VER" ] && INSTALLED_VER=$(grep -a -o -m1 'DaVinci Resolve [0-9][0-9.]*' \
    /opt/resolve/docs/Welcome.txt 2>/dev/null \
    | grep -o '[0-9][0-9.]*' | sed 's/\.$//')
if [ -n "$INSTALLED_VER" ]; then
    echo "  installed:  $INSTALLED_VER  (/opt/resolve)"
else
    echo "  installed:  none found at /opt/resolve"
fi
if ! command -v unzip >/dev/null 2>&1; then
    farm_print_error "unzip is required: sudo apt install unzip"
    exit 1
fi
echo ""

# --- ONLINE CHECK (blackmagicdesign.com) ---
farm_print_section "Checking blackmagicdesign.com"
EDITION="${FARM_RESOLVE_EDITION:-studio}"
PRODUCT_SLUG="davinci-resolve-studio"
[ "$EDITION" = "free" ] && PRODUCT_SLUG="davinci-resolve"
API_URL="https://www.blackmagicdesign.com/api/support/latest-stable-version/${PRODUCT_SLUG}/linux"
REMOTE_VER=""
farm_spin_start "looking up newest release"
API_JSON=$(curl -fsSL --connect-timeout 8 "$API_URL" 2>/dev/null)
farm_spin_stop
if [ -n "$API_JSON" ]; then
    _major=$(echo "$API_JSON" | grep -o '"major":[0-9]*' | head -1 | grep -o '[0-9]*')
    _minor=$(echo "$API_JSON" | grep -o '"minor":[0-9]*' | head -1 | grep -o '[0-9]*')
    _rel=$(echo "$API_JSON" | grep -o '"releaseNum":[0-9]*' | head -1 | grep -o '[0-9]*')
    if [ -n "$_major" ] && [ -n "$_minor" ]; then
        REMOTE_VER="${_major}.${_minor}${_rel:+.$_rel}"
        REMOTE_VER="${REMOTE_VER%.0}"
    fi
fi
if [ -n "$REMOTE_VER" ]; then
    echo "  newest:     $REMOTE_VER"
    if [ "$(farm_install_classify "$INSTALLED_VER" "$REMOTE_VER")" = "uptodate" ]; then
        echo ""
        farm_print_summary "already up to date (${INSTALLED_VER})"
        exit 0
    fi
else
    farm_print_warn "blackmagicdesign.com not reachable."
fi
echo ""

# --- AUTO-DOWNLOAD ---
# The support page's "Download Only" button POSTs downloadOnly:true
# and gets a signed one-time URL back - no registration data needed.
DOWNLOAD_ID=$(echo "$API_JSON" | grep -o '"downloadId":"[a-f0-9]*"' \
    | head -1 | cut -d'"' -f4)
if [ -n "$REMOTE_VER" ] && [ -n "$DOWNLOAD_ID" ] \
    && ! ls "$SEARCH_DIR"/DaVinci_Resolve_*"${REMOTE_VER}"*Linux.zip >/dev/null 2>&1; then
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
            echo "  [dry-run] request download link (id $DOWNLOAD_ID)"
            echo "  [dry-run] download zip to install share"
            echo ""
        else
            farm_spin_start "requesting download link"
            REG_RESP=$(curl -fsS --connect-timeout 10 -X POST \
                -H "Content-Type: application/json" \
                -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64)" \
                -H "Referer: https://www.blackmagicdesign.com/products/davinciresolve" \
                -d '{"downloadOnly":true,"platform":"Linux","policy":true,"country":"de"}' \
                "https://www.blackmagicdesign.com/api/register/us/download/${DOWNLOAD_ID}" \
                2>/dev/null)
            DL_URL=$(echo "$REG_RESP" | grep -oE 'https://[^" ]*\.zip[^" ]*' | head -1)
            farm_spin_stop
            if [ -z "$DL_URL" ]; then
                farm_print_warn "No download link returned - get it manually:"
                echo "  https://www.blackmagicdesign.com/support/"
                echo ""
            else
                mkdir -p "$SEARCH_DIR" 2>/dev/null
                if [ ! -d "$SEARCH_DIR" ]; then
                    farm_print_error "Install directory not found: $SEARCH_DIR"
                    echo "  Check that the network share is mounted."
                    exit 1
                fi
                DL_NAME=$(basename "${DL_URL%%\?*}")
                CURL_PROGRESS='-#'
                [ -t 1 ] || CURL_PROGRESS='-s'
                echo "  downloading ${DL_NAME}"
                if ! curl -fL --connect-timeout 10 $CURL_PROGRESS \
                    -o "$SEARCH_DIR/$DL_NAME.part" "$DL_URL"; then
                    rm -f "$SEARCH_DIR/$DL_NAME.part"
                    farm_print_error "Download failed."
                    exit 1
                fi
                # No published checksum; test the zip before accepting.
                farm_spin_start "verifying zip integrity"
                unzip -t -qq "$SEARCH_DIR/$DL_NAME.part" >/dev/null 2>&1
                RC=$?
                farm_spin_stop
                if [ "$RC" -ne 0 ]; then
                    rm -f "$SEARCH_DIR/$DL_NAME.part"
                    farm_print_error "Corrupt zip - download discarded."
                    exit 1
                fi
                mv "$SEARCH_DIR/$DL_NAME.part" "$SEARCH_DIR/$DL_NAME"
                farm_print_ok "Downloaded and verified."
                echo ""
            fi
        fi
    fi
fi

# --- AUTO-DETECT DOWNLOADED ZIPS ---
# The zip must be downloaded manually (registration form); scan the
# usual landing spots, sorted by version in the basename.
FOUND_ZIP=$(for f in "$HOME"/$FILE_GLOB "$HOME/Downloads"/$FILE_GLOB; do
        [ -f "$f" ] && printf '%s\t%s\n' "$(basename "$f")" "$f"
    done | sort -V | tail -n 1 | cut -f2)

if [ -n "$FOUND_ZIP" ] && [ ! -f "$SEARCH_DIR/$(basename "$FOUND_ZIP")" ]; then
    echo "  Found downloaded zip:"
    echo "    $(basename "$FOUND_ZIP")"
    echo "    in $(dirname "$FOUND_ZIP")"
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
            cp "$FOUND_ZIP" "$SEARCH_DIR/" || {
                farm_print_error "Copy failed."
                exit 1
            }
            farm_print_ok "Copied to install share."
        fi
    fi
    echo ""
fi

# --- PICK LATEST ZIP ---
farm_print_section "Searching latest Resolve zip"
echo "  Location:"
echo "  $SEARCH_DIR"
echo ""
LATEST_ZIP=$(ls -1 "$SEARCH_DIR"/$FILE_GLOB 2>/dev/null | sort -V | tail -n 1)
if [ -z "$LATEST_ZIP" ] && [ "$DRY_RUN" -eq 1 ] && [ -n "$FOUND_ZIP" ]; then
    # Dry-run never copies; report against the detected download.
    LATEST_ZIP="$FOUND_ZIP"
fi
if [ -z "$LATEST_ZIP" ]; then
    farm_print_error "No matching zip found."
    echo "  Download the Linux version into ~/Downloads first:"
    echo "  https://www.blackmagicdesign.com/support/"
    exit 1
fi
FILENAME_ONLY=$(basename "$LATEST_ZIP")
TARGET_VERSION=$(farm_extract_version "$FILENAME_ONLY")
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
    read -p "  Install this version? (y/N): " PROCEED
    echo ""
    if [[ ! "$PROCEED" =~ ^[Yy]$ ]]; then
        echo "  Aborted."
        exit 0
    fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [dry-run] unzip: $LATEST_ZIP"
    echo "  [dry-run] build .deb with makeresolvedeb"
    echo "  [dry-run] sudo dpkg -i <davinci-resolve*.deb>"
    farm_print_ok "Dry-run complete. No changes were made."
    exit 0
fi

# --- MAKERESOLVEDEB SCRIPT ---
# Third-party script, fetched at runtime and kept in the install
# share - never committed to this (public) repo.
MRD_DIR="$SEARCH_DIR/makeresolvedeb"
MRD_PAGE="https://www.danieltufvesson.com/makeresolvedeb"
mkdir -p "$MRD_DIR" 2>/dev/null
farm_spin_start "checking newest makeresolvedeb"
MRD_NEWEST=$(curl -fsSL --connect-timeout 8 "$MRD_PAGE" 2>/dev/null \
    | grep -oE 'makeresolvedeb_[0-9.]+_multi\.sh\.tar\.gz' | sort -uV | tail -n 1)
farm_spin_stop
if [ -n "$MRD_NEWEST" ] && [ ! -f "$MRD_DIR/$MRD_NEWEST" ]; then
    farm_spin_start "downloading $MRD_NEWEST"
    if curl -fsSL --connect-timeout 8 -o "$MRD_DIR/$MRD_NEWEST.part" \
        "https://www.danieltufvesson.com/download/?file=makeresolvedeb/$MRD_NEWEST" \
        && tar -tzf "$MRD_DIR/$MRD_NEWEST.part" >/dev/null 2>&1; then
        mv "$MRD_DIR/$MRD_NEWEST.part" "$MRD_DIR/$MRD_NEWEST"
    fi
    rm -f "$MRD_DIR/$MRD_NEWEST.part"
    farm_spin_stop
fi
MRD_TAR=$(ls -1 "$MRD_DIR"/makeresolvedeb_*_multi.sh.tar.gz 2>/dev/null \
    | sort -V | tail -n 1)
if [ -z "$MRD_TAR" ]; then
    farm_print_error "No makeresolvedeb script available (offline?)."
    echo "  Get the .sh.tar.gz from:"
    echo "  $MRD_PAGE"
    echo "  and place it in: $MRD_DIR"
    exit 1
fi

# --- UNZIP + BUILD DEB + INSTALL ---
farm_print_section "Installing"
echo "  using $(basename "$MRD_TAR")"
echo "  sudo may ask for your password."
echo ""
# Authenticate before the spinner (a prompt under it is invisible).
farm_sudo_auth || { farm_print_error "sudo authentication failed."; exit 1; }
# /var/tmp: disk-backed (the build needs several GB and /tmp may be
# tmpfs/RAM).
AVAIL_GB=$(df --output=avail -BG /var/tmp 2>/dev/null | tail -1 | tr -dc '0-9')
if [ -n "$AVAIL_GB" ] && [ "$AVAIL_GB" -lt 20 ]; then
    farm_print_warn "Low space in /var/tmp: ${AVAIL_GB}G free (~20G needed)."
fi
TMP_DIR=$(mktemp -d /var/tmp/resolve_update.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

farm_spin_start "unzipping $FILENAME_ONLY"
unzip -q -o "$LATEST_ZIP" -d "$TMP_DIR"
RC=$?
farm_spin_stop
RUN_FILE=$(find "$TMP_DIR" -maxdepth 2 -name 'DaVinci_Resolve_*Linux.run' | sort -V | tail -n 1)
if [ "$RC" -ne 0 ] || [ -z "$RUN_FILE" ]; then
    farm_print_error "Unzip failed or no .run installer in the zip."
    exit 1
fi
chmod +x "$RUN_FILE"

tar -xzf "$MRD_TAR" -C "$TMP_DIR"
MRD_SH=$(find "$TMP_DIR" -maxdepth 1 -name 'makeresolvedeb_*.sh' | head -n 1)
if [ -z "$MRD_SH" ]; then
    farm_print_error "makeresolvedeb script missing from tarball."
    exit 1
fi
chmod +x "$MRD_SH"

# The build takes several minutes; full log kept next to the build.
# makeresolvedeb rejects path arguments - cd to the .run and pass the
# bare filename.
BUILD_DIR=$(dirname "$RUN_FILE")
farm_spin_start "building deb ($(basename "$MRD_SH"))"
( cd "$BUILD_DIR" && "$MRD_SH" "$(basename "$RUN_FILE")" ) > "$TMP_DIR/mrd.log" 2>&1
RC=$?
farm_spin_stop
DEB_FILE=$(find "$BUILD_DIR" -maxdepth 1 -name 'davinci-resolve*_amd64.deb' \
    | sort -V | tail -n 1)
if [ "$RC" -ne 0 ] || [ -z "$DEB_FILE" ]; then
    farm_print_error "makeresolvedeb build failed (rc=$RC). Log tail:"
    tail -n 15 "$TMP_DIR/mrd.log" 2>/dev/null | sed 's/^/    /'
    exit 1
fi

echo "  built: $(basename "$DEB_FILE")"
echo ""
# The build can outlive sudo's credential cache; re-auth (instant when
# still cached) so dpkg never prompts unstyled mid-stream.
farm_sudo_auth || { farm_print_error "sudo authentication failed."; exit 1; }
sudo dpkg -i "$DEB_FILE" 2>&1 | farm_indent
RC=${PIPESTATUS[0]}

echo ""
farm_print_section "Verification"
NEW_VER=$(dpkg-query -W -f '${Version}' davinci-resolve-studio 2>/dev/null \
    | sed 's/-mrd.*//')
[ -z "$NEW_VER" ] && NEW_VER=$(dpkg-query -W -f '${Version}' \
    davinci-resolve 2>/dev/null | sed 's/-mrd.*//')
if [ "$RC" -eq 0 ] && [ -x /opt/resolve/bin/resolve ] && [ -n "$NEW_VER" ]; then
    echo "  binary:  /opt/resolve/bin/resolve"
    echo "  version: $NEW_VER"
    echo ""
    farm_print_summary "resolve ${NEW_VER} installed"
else
    farm_print_error "Install finished with problems (rc=$RC)."
    echo "  Check the installer output above; common fixes:"
    echo "  sudo apt install ocl-icd-opencl-dev  (libOpenCL.so)"
    exit 1
fi
