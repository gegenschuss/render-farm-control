#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
cd "$(dirname "$0")"
source ../lib/config.sh
farm_require_bash4 "license_houdini.sh"

show_help() {
    cat << 'EOF'
Usage: ./license_houdini.sh [options]

Update the Houdini license on eligible Linux farm nodes.

Opens one tmux pane per machine running:
  print-license  ->  redeem (interactive)  ->  print-license

Version upgrades (e.g. 21.0 -> 22.0) appear in the redeem list as
"modification ... (upgraded from X)" entitlements: they upgrade the
licenses ALREADY on that machine in place and consume nothing.
Review the list per pane, then press f to install or q to skip.
With panes synchronized (default), one keypress answers all panes;
unsync with Prefix+y to answer per machine. Unselect any entry that
is NOT a modification upgrade unless you want that new license
assigned to that machine.

Credentials (FARM_SIDEFX_EMAIL / FARM_SIDEFX_PASSWORD in
config/secrets.sh, or asked ONCE per run) are passed to redeem via
--email/--password - the only non-interactive auth this sesictrl
supports (oauth2 API-key flags are ignored by current builds, and
login sessions do not persist between sesictrl invocations).

Note: the workstation pane may ask for your local sudo password
once (nodes have passwordless sudo, the workstation does not).

Options:
  -h, --help      Show this help message
  -y, --yes       Auto-confirm prompts
      --dry-run   Print planned actions without executing
      --local     Include local workstation
      --no-local  Exclude local workstation

Examples:
  ./license_houdini.sh
  ./license_houdini.sh --local
  ./license_houdini.sh --yes --no-local
EOF
}

AUTO_YES=0
DRY_RUN=0
FORCE_LOCAL=""
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            show_help
            exit 0
            ;;
        -y|--yes) AUTO_YES=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --local) FORCE_LOCAL="y" ;;
        --no-local) FORCE_LOCAL="n" ;;
        *) farm_die_unknown_option "$arg" show_help ;;
    esac
done

"$FARM_SCRIPTS_DIR/lib/header.sh"
echo ""
# --- CONFIGURATION ---
X_START="$FARM_X_START"
SESSION="farm_license_houdini"

farm_print_title "HOUDINI LICENSE UPDATE"

# --- LOCAL WORKSTATION? ---
if [ -n "$FORCE_LOCAL" ]; then
    LICENSE_LOCAL="$FORCE_LOCAL"
else
    farm_prompt_rule
    read -p "Update license on local workstation ($FARM_LOCAL_NAME) too? (y/n, q=cancel): " LICENSE_LOCAL
    echo ""
    if [[ "$LICENSE_LOCAL" == "q" || "$LICENSE_LOCAL" == "Q" ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# Best-effort: version(s) of the Houdini licenses installed on a machine
# ("" = local). Empty result if sesictrl is missing or unreadable.
# Whether an UPGRADE is pending only shows in the pane's redeem list -
# entitlements can't be queried without credentials, so the pre-flight
# reports the installed state and the panes do the actual check.
license_versions() {
    local node="$1" out
    local probe='S=/usr/lib/sesi/sesictrl; [ -x "$S" ] || S=$(ls -1 /opt/hfs*/bin/sesictrl 2>/dev/null | sort -V | tail -n 1); [ -n "$S" ] && sudo -n "$S" print-license </dev/null 2>/dev/null | grep -E "^Lic " | grep -oE "[0-9]+\.[0-9]+" | sort -uV | paste -sd "/" -'
    if [ -z "$node" ]; then
        out=$(timeout 15 bash -c "$probe" 2>/dev/null)
        # The workstation has no passwordless sudo for sesictrl;
        # print-license works without sudo there.
        [ -z "$out" ] && out=$(timeout 15 bash -c "${probe//sudo -n /}" 2>/dev/null)
    else
        out=$(timeout 15 ssh -n -F ~/.ssh/config -o LogLevel=ERROR "$node" "$probe" 2>/dev/null)
    fi
    echo "$out"
}

# --- CHECK NODE STATUS ---
echo ""
farm_print_section "Checking node status"
echo ""
declare -A NODE_OS
for NODE in "${NODES[@]}"; do
    # Probe over ssh (the same channel the license update runs on) rather
    # than a bare-name ping - see install_app.sh for why ping can disagree.
    farm_spin_start "checking $NODE"
    farm_get_node_os_status "$NODE" "ssh"
    NODE_OS[$NODE]=$?
    case ${NODE_OS[$NODE]} in
        0)
            farm_spin_stop
            echo "$(farm_node_tag "$NODE") offline - skipped"
            ;;
        1)
            farm_spin_stop
            echo "$(farm_node_tag "$NODE") on Windows - skipped"
            ;;
        2)
            VER=$(license_versions "$NODE")
            farm_spin_stop
            echo "$(farm_node_tag "$NODE") on Linux - licenses: ${VER:-none found} - will check"
            ;;
    esac
done

if [[ "$LICENSE_LOCAL" =~ ^[Yy]$ ]]; then
    farm_spin_start "checking $FARM_LOCAL_NAME"
    VER=$(license_versions "")
    farm_spin_stop
    echo "$(farm_node_tag "$FARM_LOCAL_NAME") local workstation - licenses: ${VER:-none found} - will check"
else
    echo "$(farm_node_tag "$FARM_LOCAL_NAME") local workstation - skipped"
fi

echo ""
if [ "$AUTO_YES" -eq 1 ]; then
    echo "Auto-yes enabled: starting license update."
else
    if ! farm_press_any_or_q "Press any key to start, q to abort"; then
        echo "Aborted."
        exit 0
    fi
fi
echo ""

if [ "$DRY_RUN" -eq 1 ]; then
    farm_print_ok "Dry-run complete. No changes were made."
    echo ""
    exit 0
fi

# --- SIDEFX CREDENTIALS ---
# sesictrl only honors --email + --password for non-interactive auth
# (its oauth2 flags --client-id/--client-secret/--access-token are ignored
# by current builds and fall back to the interactive email prompt, and
# login sessions do not persist between invocations - tested against
# sesinetd 21/22, Aug 2026). So: email/password from config/secrets.sh,
# or asked ONCE here and passed to redeem on every machine.
SFX_EMAIL="${FARM_SIDEFX_EMAIL:-}"
SFX_PASS="${FARM_SIDEFX_PASSWORD:-}"

farm_print_section "SideFX account login"
echo ""
if [ -n "$SFX_EMAIL" ] && [ -n "$SFX_PASS" ]; then
    echo "Using SideFX account from config/secrets.sh: $SFX_EMAIL"
    echo ""
else
    echo "Tip: set FARM_SIDEFX_EMAIL / FARM_SIDEFX_PASSWORD in"
    echo "config/secrets.sh to skip this prompt."
    echo ""
    if [ -n "$SFX_EMAIL" ]; then
        read -p "SideFX account email [$SFX_EMAIL] (q=cancel): " SFX_EMAIL_IN
        if [[ "$SFX_EMAIL_IN" == "q" || "$SFX_EMAIL_IN" == "Q" ]]; then
            echo "Aborted."
            exit 0
        fi
        [ -n "$SFX_EMAIL_IN" ] && SFX_EMAIL="$SFX_EMAIL_IN"
    fi
    while [ -z "$SFX_EMAIL" ]; do
        read -p "SideFX account email (q=cancel): " SFX_EMAIL
        if [[ "$SFX_EMAIL" == "q" || "$SFX_EMAIL" == "Q" ]]; then
            echo "Aborted."
            exit 0
        fi
    done
    if [ -z "$SFX_PASS" ]; then
        read -s -p "SideFX account password: " SFX_PASS
        echo ""
        if [ -z "$SFX_PASS" ]; then
            echo "No password entered. Aborted."
            exit 0
        fi
    fi
    echo ""
fi

# --- PER-MACHINE LICENSE SCRIPT ---
# Runs print-license -> interactive redeem -> print-license via sesictrl.
# The script contains quotes/newlines, so it is base64-wrapped for ssh
# (same as install_app.sh).
# Credentials are injected as a %q-quoted prefix so any special characters
# survive the round trip.
CRED_PREFIX=$(printf 'SFX_EMAIL=%q\nSFX_PASS=%q' "$SFX_EMAIL" "$SFX_PASS")
LICENSE_SCRIPT="$CRED_PREFIX
$(cat << 'EOS'
set -u
SESI="/usr/lib/sesi/sesictrl"
if [ ! -x "$SESI" ]; then
    SESI=$(ls -1 /opt/hfs*/bin/sesictrl 2>/dev/null | sort -V | tail -n 1)
fi
if [ -z "${SESI:-}" ] || [ ! -x "$SESI" ]; then
    echo -e '\e[31mERROR: sesictrl not found (/usr/lib/sesi, /opt/hfs*/bin)\e[0m'
    echo 'Press Enter to exit.'
    read
    exit 1
fi
echo "Using: $SESI"
echo ""
echo "--- 1/3 CURRENT LICENSES ---"
sudo "$SESI" print-license
echo ""
echo "--- 2/3 REDEEM / UPGRADE (interactive) ---"
# Version upgrades (e.g. 21.0 -> 22.0) arrive as "modification ...
# (upgraded from X)" entitlements: they upgrade a license ALREADY on this
# machine in place and consume nothing. sesictrl sync-licenses can NOT do
# this (it fails with "Failed to install 00000000"); redeem is the correct
# and only path. The list below is interactive: review it, then press
#   f = install what is selected     q = quit without installing
# Unselect anything that is NOT a "modification" upgrade (type its number)
# unless you really want to assign that new license to THIS machine.
echo 'In the list below: "modifcation ... upgraded from X" entries are'
echo 'in-place version upgrades of licenses already on this machine.'
echo 'Press f to install the selection, q to skip this machine.'
echo 'Unselect (by number) anything that is NOT such an upgrade.'
echo ""
sudo "$SESI" redeem --email "$SFX_EMAIL" --password "$SFX_PASS"
unset SFX_PASS
echo ""
echo "--- 3/3 LICENSES AFTER ---"
sudo "$SESI" print-license
echo ""
echo '--- LICENSE UPDATE DONE ---'
echo 'Press Enter to exit.'
read
EOS
)"
B64_LICENSE=$(echo "$LICENSE_SCRIPT" | base64 -w 0)
# eval "$(... | base64 -d)" instead of "... | base64 -d | bash": piping the
# script into bash makes the exhausted pipe its stdin, which is exactly what
# sends EOF to interactive prompts (the sesictrl endless-loop trigger) and
# would also skip the final "Press Enter" read. eval keeps the tty as stdin.
REMOTE_FINAL_CMD="bash -c 'eval \"\$(echo $B64_LICENSE | base64 -d)\"'"
LOCAL_CMD="$REMOTE_FINAL_CMD"

# --- TMUX SETUP ---
farm_tmux_reset_session "$SESSION"

for NODE in "${NODES[@]}"; do
    OS=${NODE_OS[$NODE]}

    # Only open panes for nodes that are up on Linux
    if [ "$OS" -ne 2 ]; then
        continue
    fi

    NODE_CMD="ssh -t -F ~/.ssh/config -o LogLevel=ERROR $NODE \"$REMOTE_FINAL_CMD\""
    farm_tmux_add_pane "$SESSION" "$NODE_CMD" "NODE: $NODE"
done

# --- LOCAL WORKSTATION PANE ---
if [[ "$LICENSE_LOCAL" =~ ^[Yy]$ ]]; then
    farm_tmux_add_pane "$SESSION" "$LOCAL_CMD" "$FARM_LOCAL_NAME"
fi

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    farm_print_warn "No eligible machines - nothing to do."
    echo ""
    exit 0
fi

# --- APPLY SHARED TMUX CONFIG ---
farm_tmux_apply_config "$SESSION"

# --- SELECT LOCAL PANE AS ACTIVE ---
if [[ "$LICENSE_LOCAL" =~ ^[Yy]$ ]]; then
    LOCAL_PANE=$(tmux list-panes -t $SESSION -F '#{pane_index}' | tail -1)
    tmux select-pane -t "$SESSION.$LOCAL_PANE"
fi

# --- LAUNCH TERMINAL ---
farm_launch_terminal \
    "farm-license" "$X_START" "$SESSION" 1.0
