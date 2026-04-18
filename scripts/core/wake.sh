#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
cd "$(dirname "$0")"
source ../lib/config.sh
farm_require_bash4 "wake.sh"
source ../lib/wake_lib.sh

show_help() {
    local script_path
    script_path="$(pwd)/wake.sh"
    cat << 'EOF'
Usage: ./wake.sh [options]

Wake farm nodes and handle dual-boot nodes for Linux startup.

Options:
  -h, --help              Show this help message
  -y, --yes               Compatibility flag (no override prompts in wake flow)
      --dry-run           Print planned actions without executing them
      --prejob            Non-interactive pre-job mode (no tmux monitor)
      --silent            Non-interactive scheduler mode
                          Skips all nodes currently on Windows
      --silent-strict
                          Like --silent, but requires all targeted
                          nodes to respond before success
      --deadline-prejob   Compatibility alias of --silent
      --deadline-prejob-strict
                          Compatibility alias of --silent-strict
      --no-tmux           Alias of --prejob
      --console-only      Alias of --prejob
      --prejob-wait=SEC   Max wait for readiness in pre-job mode (default: 30)

Pre-job logging:
  --prejob writes to /tmp/farm_wake_prejob.log
  --silent writes to /tmp/farm_wake_silent.log
  Override path with FARM_PREJOB_LOG_FILE=/path/to/file.log
  Linux SSH probe interval: FARM_PREJOB_SSH_PROBE_INTERVAL (default: 10s)

Examples:
  ./wake.sh
  ./wake.sh --prejob --prejob-wait=45
  FARM_PREJOB_LOG_FILE=/tmp/custom_wake.log ./wake.sh --prejob --prejob-wait=120
  ./wake.sh --yes --dry-run
EOF
    echo ""
    echo "Silent mode example:"
    echo "  $script_path --silent --prejob-wait=45"
    echo "  $script_path --silent-strict --prejob-wait=60"
}

# Non-interactive mode usage:
# - no logo animation
# - no interactive prompts
# - no tmux monitor/terminal launch
PREJOB_MODE=0
PREJOB_WAIT_SECONDS=${FARM_PREJOB_WAIT_SECONDS:-30}
PREJOB_SSH_PROBE_INTERVAL=${FARM_PREJOB_SSH_PROBE_INTERVAL:-10}
AUTO_YES=0
DRY_RUN=0
DEADLINE_PREJOB=0
DEADLINE_STRICT=0
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            show_help
            exit 0
            ;;
        --prejob|--no-tmux|--console-only)
            PREJOB_MODE=1
            ;;
        --silent|--deadline-prejob)
            PREJOB_MODE=1
            DEADLINE_PREJOB=1
            AUTO_YES=1
            ;;
        --silent-strict|--deadline-prejob-strict)
            PREJOB_MODE=1
            DEADLINE_PREJOB=1
            DEADLINE_STRICT=1
            AUTO_YES=1
            ;;
        --prejob-wait=*)
            PREJOB_WAIT_SECONDS="${arg#*=}"
            ;;
        --yes|-y)
            AUTO_YES=1
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        *) farm_die_unknown_option "$arg" show_help ;;
    esac
done

if ! [[ "$PREJOB_WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
    farm_print_warn "Invalid --prejob-wait value; using default (30s)."
    PREJOB_WAIT_SECONDS=30
fi
if ! [[ "$PREJOB_SSH_PROBE_INTERVAL" =~ ^[0-9]+$ ]] || [ "$PREJOB_SSH_PROBE_INTERVAL" -le 0 ]; then
    PREJOB_SSH_PROBE_INTERVAL=10
fi

if [ "$PREJOB_MODE" -eq 1 ]; then
    if [ "$DEADLINE_PREJOB" -eq 1 ]; then
        farm_disable_colors
        PREJOB_LOG_FILE="${FARM_PREJOB_LOG_FILE:-/tmp/farm_wake_silent.log}"
    else
        PREJOB_LOG_FILE="${FARM_PREJOB_LOG_FILE:-/tmp/farm_wake_prejob.log}"
    fi
    exec > >(tee -a "$PREJOB_LOG_FILE") 2>&1
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Pre-job mode started."
    echo "Log file: $PREJOB_LOG_FILE"
    if [ "$DEADLINE_PREJOB" -eq 1 ]; then
        echo "Policy: silent mode (skip all nodes currently on Windows; no user interaction)."
    fi
    if [ "$DEADLINE_STRICT" -eq 1 ]; then
        echo "Readiness mode: strict (all targeted nodes must respond)."
    else
        echo "Readiness mode: first-response (any target node response is success)."
    fi
    echo ""
fi

if [ "$PREJOB_MODE" -eq 0 ]; then
    "$FARM_SCRIPTS_DIR/lib/header.sh"
fi
echo ""

# === MAIN SCRIPT START ===
# --- CONFIGURATION ---
X_START="$FARM_X_START"
SESSION="farm_startup"
USE_TMUX_MONITOR=1
if [[ "${FARM_OS:-linux}" == "linux" || "${FARM_OS:-linux}" == "mac" ]]; then
    if [ "${FARM_USE_TMUX_MONITOR:-0}" -ne 1 ]; then
        USE_TMUX_MONITOR=0
    fi
fi
LIVE_TABLE_MODE=0
if [ "$PREJOB_MODE" -eq 0 ] && [ "$USE_TMUX_MONITOR" -eq 0 ]; then
    LIVE_TABLE_MODE=1
fi

farm_print_title "FARM WAKE / STARTUP"

send_wol_for_node() {
    local target_node="$1"
    local mac_addr
    mac_addr="$(farm_get_node_mac "$target_node")"
    if [ -z "$mac_addr" ]; then
        farm_print_warn "$(farm_node_tag "$target_node") no MAC configured - cannot send WOL"
        return 1
    fi
    if [ "$LIVE_TABLE_MODE" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
        wakeonlan "$mac_addr" >/dev/null 2>&1
    else
        run_or_print wakeonlan "$mac_addr"
    fi
    sleep 1
}

trigger_dualboot_reboot_to_linux() {
    local target_node="$1"
    local bios_guid="$2"

    if [ "$LIVE_TABLE_MODE" -eq 0 ]; then
        echo "$(farm_node_tag "$target_node") sending reboot-to-Linux command (non-interactive)..."
    fi
    if [ "$LIVE_TABLE_MODE" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
        farm_ssh "${target_node}-win" \
            "powershell -Command \"bcdedit /set '{fwbootmgr}' bootsequence '$bios_guid'\"" >/dev/null 2>&1
        farm_ssh "${target_node}-win" "shutdown /r /t 5" >/dev/null 2>&1
    else
        run_or_print farm_ssh "${target_node}-win" \
            "powershell -Command \"bcdedit /set '{fwbootmgr}' bootsequence '$bios_guid'\""
        run_or_print farm_ssh "${target_node}-win" "shutdown /r /t 5"
    fi
}

print_plain_subheading() {
    local text="$1"
    echo "$text"
    echo ""
}

print_colored_node_inventory() {
    echo "Configured nodes:"
    for node in "${NODES[@]}"; do
        if farm_is_dual_boot_node "$node"; then
            printf "  ${FARM_C_NODE}%s${FARM_C_RESET} (%s)\n" "$node" "dual-boot"
        else
            printf "  ${FARM_C_NODE}%s${FARM_C_RESET}\n" "$node"
        fi
    done
    echo ""
}


# --- MAGIC PACKETS ---
if [ "$LIVE_TABLE_MODE" -eq 0 ]; then
    print_colored_node_inventory
fi
print_plain_subheading "Sending Wake-on-LAN packets"
farm_print_ok "Starting node checks and wake flow..."
echo ""
declare -A WAKE_NODE_SUMMARY

# --- PARALLEL PRE-CHECKS ---
# Run all pings and dual-boot SSH checks concurrently so the live table
# appears immediately instead of after N sequential timeouts.
declare -A LINUX_STATUS
declare -A DUALBOOT_STATUS
declare -A DUALBOOT_REBOOT_ISSUED
declare -A DUALBOOT_LAST_SSH_PROBE
declare -A DUALBOOT_SSH_READY

_precheck_tmp=$(mktemp -d)
trap 'rm -rf "$_precheck_tmp"' EXIT

# Start linux node pings in parallel
declare -a _linux_nodes=()
declare -a _linux_pids=()
for NODE in "${NODES[@]}"; do
    if farm_is_dual_boot_node "$NODE"; then continue; fi
    _linux_nodes+=("$NODE")
    ( ping -c 1 -W 1 "$NODE" &>/dev/null && echo online || echo offline \
    ) > "$_precheck_tmp/linux_${NODE}.out" &
    _linux_pids+=($!)
done

# Start dual-boot status checks in parallel
declare -a _db_names=()
declare -a _db_pids=()
for NODE_DEF in "${DUAL_BOOT_NODES[@]}"; do
    IFS='|' read -r NAME BIOS_GUID LINUX_WAIT WIN_USER <<< "$NODE_DEF"
    _db_names+=("$NAME|$BIOS_GUID|$LINUX_WAIT|$WIN_USER")
    ( check_dualboot_status "$NAME" "$WIN_USER" >/dev/null 2>&1
      echo $?
    ) > "$_precheck_tmp/db_${NAME}.out" &
    _db_pids+=($!)
done

# Wait for all checks
for _pid in "${_linux_pids[@]}" "${_db_pids[@]}"; do
    wait "$_pid" 2>/dev/null
done

# --- LINUX NODES: collect results ---
for NODE in "${_linux_nodes[@]}"; do
    _result=$(cat "$_precheck_tmp/linux_${NODE}.out" 2>/dev/null)
    if [ "$_result" = "online" ]; then
        if [ "$LIVE_TABLE_MODE" -eq 0 ]; then
            echo "$(farm_node_tag "$NODE") already online - skipping WOL"
        fi
        LINUX_STATUS[$NODE]="online"
        WAKE_NODE_SUMMARY[$NODE]="already online - WOL skipped"
    else
        if [ "$LIVE_TABLE_MODE" -eq 0 ]; then
            echo "$(farm_node_tag "$NODE") offline - sending WOL..."
        fi
        LINUX_STATUS[$NODE]="offline"
        if send_wol_for_node "$NODE"; then
            WAKE_NODE_SUMMARY[$NODE]="WOL sent ($(farm_get_node_mac "$NODE"))"
        else
            WAKE_NODE_SUMMARY[$NODE]="WOL failed (no MAC)"
        fi
    fi
done

# --- DUAL BOOT NODES: collect results ---
for _db_entry in "${_db_names[@]}"; do
    IFS='|' read -r NAME BIOS_GUID LINUX_WAIT WIN_USER <<< "$_db_entry"
    STATUS=$(cat "$_precheck_tmp/db_${NAME}.out" 2>/dev/null)
    if ! [[ "$STATUS" =~ ^[0-9]+$ ]]; then STATUS=0; fi
    DUALBOOT_STATUS[$NAME]=$STATUS
    DUALBOOT_REBOOT_ISSUED[$NAME]=0
    DUALBOOT_LAST_SSH_PROBE[$NAME]=-9999
    DUALBOOT_SSH_READY[$NAME]=0

    if [ $STATUS -eq 0 ]; then
        if send_wol_for_node "$NAME"; then
            WAKE_NODE_SUMMARY[$NAME]="WOL sent ($(farm_get_node_mac "$NAME")); booting to Linux"
        else
            WAKE_NODE_SUMMARY[$NAME]="WOL failed (no MAC)"
        fi
        [ "$LIVE_TABLE_MODE" -eq 0 ] && echo "$(farm_node_tag "$NAME") offline → will send WOL"
        # In non-interactive prejob mode, offline dual-boot nodes often boot
        # into Windows first. Defer the reboot-to-Linux until Win SSH is up.
    elif [ $STATUS -eq 1 ] && [ "$PREJOB_MODE" -eq 1 ] && [ "$DEADLINE_PREJOB" -eq 0 ]; then
        [ "$LIVE_TABLE_MODE" -eq 0 ] && echo "$(farm_node_tag "$NAME") on Windows, idle → will reboot to Linux"
        trigger_dualboot_reboot_to_linux "$NAME" "$BIOS_GUID"
        DUALBOOT_REBOOT_ISSUED[$NAME]=1
        DUALBOOT_LAST_SSH_PROBE[$NAME]=-9999
    fi
    case $STATUS in
        0) : ;;
        1)
            WAKE_NODE_SUMMARY[$NAME]="Windows idle - reboot to Linux queued"
            [ "$LIVE_TABLE_MODE" -eq 0 ] && [ "$PREJOB_MODE" -eq 0 ] && echo "$(farm_node_tag "$NAME") on Windows, idle → will reboot to Linux"
            ;;
        2)
            WAKE_NODE_SUMMARY[$NAME]="ARTIST WORKING or UPDATE ACTIVE - skipped"
            [ "$LIVE_TABLE_MODE" -eq 0 ] && echo "$(farm_node_tag "$NAME") on Windows, user active → skipping"
            ;;
        3)
            WAKE_NODE_SUMMARY[$NAME]="already on Linux"
            [ "$LIVE_TABLE_MODE" -eq 0 ] && echo "$(farm_node_tag "$NAME") on Linux → no action needed"
            ;;
        5)
            WAKE_NODE_SUMMARY[$NAME]="on Windows - skipped by silent policy"
            [ "$LIVE_TABLE_MODE" -eq 0 ] && echo "$(farm_node_tag "$NAME") on Windows → skipped (silent policy)"
            ;;
    esac
done

rm -rf "$_precheck_tmp"

if [ "$DRY_RUN" -eq 1 ]; then
    farm_print_ok "Dry-run complete. No changes were made."
    echo ""
    exit 0
fi

# --- STATUS SUMMARY ---
if [ "$LIVE_TABLE_MODE" -eq 0 ]; then
    farm_prompt_rule
    print_plain_subheading "Farm status summary"
    for NODE in "${NODES[@]}"; do
        farm_print_node_summary_line "$NODE" "${WAKE_NODE_SUMMARY[$NODE]}"
    done
    echo ""
fi

# --- CHECK IF ANY NODES NEED MONITORING ---
NEEDS_MONITORING=0

for NODE in "${NODES[@]}"; do
    if ! farm_is_dual_boot_node "$NODE"; then
        if [ "${LINUX_STATUS[$NODE]}" = "offline" ]; then
            NEEDS_MONITORING=1
            break
        fi
    fi
done

if [ $NEEDS_MONITORING -eq 0 ]; then
    for NODE_DEF in "${DUAL_BOOT_NODES[@]}"; do
        IFS='|' read -r NAME BIOS_GUID LINUX_WAIT WIN_USER <<< "$NODE_DEF"
        STATUS=${DUALBOOT_STATUS[$NAME]}
        if [ $STATUS -eq 0 ] || \
           { [ $STATUS -eq 1 ] && [ "$DEADLINE_PREJOB" -eq 0 ]; }; then
            NEEDS_MONITORING=1
            break
        fi
    done
fi

if [ $NEEDS_MONITORING -eq 0 ]; then
    farm_print_ok "All targeted Linux nodes are already online. Nothing to monitor."
    exit 0
fi

if [ "$PREJOB_MODE" -eq 1 ]; then
    print_plain_subheading "Pre-job readiness check"
    echo "Polling up to ${PREJOB_WAIT_SECONDS}s for node response..."

    ELAPSED=0
    TARGET_COUNT=0
    RESPONDED_COUNT=0
    PENDING_REBOOT_ISSUE_COUNT=0

    while [ "$ELAPSED" -le "$PREJOB_WAIT_SECONDS" ]; do
        TARGET_COUNT=0
        RESPONDED_COUNT=0
        PENDING_REBOOT_ISSUE_COUNT=0

        # Regular Linux nodes targeted by WOL
        for NODE in "${NODES[@]}"; do
            if farm_is_dual_boot_node "$NODE"; then
                continue
            fi
            if [ "${LINUX_STATUS[$NODE]}" = "offline" ]; then
                ((TARGET_COUNT++))
                if ping -c 1 -W 1 "$NODE" &>/dev/null; then
                    ((RESPONDED_COUNT++))
                fi
            fi
        done

        # Dual-boot nodes targeted for boot/reboot to Linux
        for NODE_DEF in "${DUAL_BOOT_NODES[@]}"; do
            IFS='|' read -r NAME BIOS_GUID LINUX_WAIT WIN_USER <<< "$NODE_DEF"
            STATUS=${DUALBOOT_STATUS[$NAME]}
            # If an offline dual-boot node comes up on Windows first, send a
            # one-time reboot-to-Linux command once Win SSH is reachable.
            if [ "$PREJOB_MODE" -eq 1 ] && [ "$STATUS" -eq 0 ] && \
               [ "${DUALBOOT_REBOOT_ISSUED[$NAME]}" -eq 0 ]; then
                if farm_ssh_timeout 3 "${NAME}-win" "echo ok" &>/dev/null; then
                    trigger_dualboot_reboot_to_linux "$NAME" "$BIOS_GUID"
                    DUALBOOT_REBOOT_ISSUED[$NAME]=1
                    DUALBOOT_LAST_SSH_PROBE[$NAME]=-9999
                fi
            fi

            # After reboot-to-Linux is issued, probe Linux SSH every N seconds.
            if [ "${DUALBOOT_REBOOT_ISSUED[$NAME]}" -eq 1 ] && [ "${DUALBOOT_SSH_READY[$NAME]}" -eq 0 ]; then
                local_last_probe=${DUALBOOT_LAST_SSH_PROBE[$NAME]}
                if [ $((ELAPSED - local_last_probe)) -ge "$PREJOB_SSH_PROBE_INTERVAL" ]; then
                    DUALBOOT_LAST_SSH_PROBE[$NAME]=$ELAPSED
                    if farm_ssh_timeout 3 "$NAME" "echo ok" &>/dev/null; then
                        DUALBOOT_SSH_READY[$NAME]=1
                    fi
                fi
            fi
            if [ "$STATUS" -eq 0 ] || \
               { [ "$STATUS" -eq 1 ] && [ "$DEADLINE_PREJOB" -eq 0 ]; }; then
                ((TARGET_COUNT++))
                # Dual-boot nodes are only "ready" when Linux SSH responds.
                if [ "${DUALBOOT_SSH_READY[$NAME]}" -eq 1 ]; then
                    ((RESPONDED_COUNT++))
                fi
            fi
            if [ "$STATUS" -eq 0 ] && [ "${DUALBOOT_REBOOT_ISSUED[$NAME]}" -eq 0 ]; then
                ((PENDING_REBOOT_ISSUE_COUNT++))
            fi
        done

        if [ "$TARGET_COUNT" -eq 0 ]; then
            break
        fi

        if [ "$DEADLINE_STRICT" -eq 1 ]; then
            if [ "$RESPONDED_COUNT" -eq "$TARGET_COUNT" ] && \
               [ "$TARGET_COUNT" -gt 0 ] && \
               [ "$PENDING_REBOOT_ISSUE_COUNT" -eq 0 ]; then
                farm_print_ok "Pre-job readiness (strict): ${RESPONDED_COUNT}/${TARGET_COUNT} target node(s) Linux-ready."
                echo ""
                farm_print_ok "Pre-job mode: wake/reboot commands sent. Skipping tmux monitor."
                echo ""
                exit 0
            fi
        else
            if [ "$RESPONDED_COUNT" -gt 0 ] && [ "$PENDING_REBOOT_ISSUE_COUNT" -eq 0 ]; then
                farm_print_ok "Pre-job readiness: ${RESPONDED_COUNT}/${TARGET_COUNT} target node(s) Linux-ready."
                echo ""
                farm_print_ok "Pre-job mode: wake/reboot commands sent. Skipping tmux monitor."
                echo ""
                exit 0
            fi
        fi

        sleep 2
        ((ELAPSED+=2))
    done

    if [ "$TARGET_COUNT" -gt 0 ]; then
        if [ "$PENDING_REBOOT_ISSUE_COUNT" -gt 0 ]; then
            farm_print_error "Pre-job readiness failed: ${PENDING_REBOOT_ISSUE_COUNT} dual-boot node(s) never reached Windows SSH for reboot-to-Linux within ${PREJOB_WAIT_SECONDS}s."
            echo ""
            echo "  Node readiness summary:"
            for NODE in "${NODES[@]}"; do
                if farm_is_dual_boot_node "$NODE"; then
                    if [ "${DUALBOOT_SSH_READY[$NODE]:-0}" -eq 1 ]; then
                        echo "    $NODE:  online (ready)"
                    elif [ "${DUALBOOT_REBOOT_ISSUED[$NODE]:-0}" -eq 0 ]; then
                        echo "    $NODE:  TIMEOUT - Windows SSH never reachable after ${PREJOB_WAIT_SECONDS}s"
                    else
                        echo "    $NODE:  TIMEOUT - not on Linux after ${PREJOB_WAIT_SECONDS}s"
                    fi
                else
                    if [ "${LINUX_STATUS[$NODE]}" = "online" ]; then
                        echo "    $NODE:  online (ready)"
                    else
                        echo "    $NODE:  offline"
                    fi
                fi
            done
            echo ""
            exit 2
        fi
        if [ "$DEADLINE_STRICT" -eq 1 ]; then
            if [ "$RESPONDED_COUNT" -lt "$TARGET_COUNT" ]; then
                farm_print_error "Pre-job readiness failed (strict): ${RESPONDED_COUNT}/${TARGET_COUNT} target node(s) Linux-ready within ${PREJOB_WAIT_SECONDS}s."
                echo ""
                echo "  Node readiness summary:"
                for NODE in "${NODES[@]}"; do
                    if farm_is_dual_boot_node "$NODE"; then
                        if [ "${DUALBOOT_SSH_READY[$NODE]:-0}" -eq 1 ]; then
                            echo "    $NODE:  online (ready)"
                        else
                            echo "    $NODE:  TIMEOUT - not on Linux after ${PREJOB_WAIT_SECONDS}s"
                        fi
                    else
                        if [ "${LINUX_STATUS[$NODE]}" = "online" ]; then
                            echo "    $NODE:  online (ready)"
                        elif ping -c 1 -W 1 "$NODE" &>/dev/null; then
                            echo "    $NODE:  online (ready)"
                        else
                            echo "    $NODE:  offline"
                        fi
                    fi
                done
                echo ""
                exit 2
            fi
        elif [ "$RESPONDED_COUNT" -eq 0 ]; then
            farm_print_error "Pre-job readiness failed: no target nodes responded within ${PREJOB_WAIT_SECONDS}s."
            echo ""
            echo "  Node readiness summary:"
            for NODE in "${NODES[@]}"; do
                if farm_is_dual_boot_node "$NODE"; then
                    if [ "${DUALBOOT_SSH_READY[$NODE]:-0}" -eq 1 ]; then
                        echo "    $NODE:  online (ready)"
                    else
                        echo "    $NODE:  TIMEOUT - not on Linux after ${PREJOB_WAIT_SECONDS}s"
                    fi
                else
                    if [ "${LINUX_STATUS[$NODE]}" = "online" ]; then
                        echo "    $NODE:  online (ready)"
                    else
                        echo "    $NODE:  offline"
                    fi
                fi
            done
            echo ""
            exit 2
        fi
    fi

    echo ""
    farm_print_ok "Pre-job mode: wake/reboot commands sent. Skipping tmux monitor."
    echo ""
    exit 0
fi

if [ "$USE_TMUX_MONITOR" -eq 1 ]; then
    print_plain_subheading "Launch monitor"
    echo "Starting tmux monitor..."
    echo ""
fi

if [ "$USE_TMUX_MONITOR" -eq 0 ]; then
    declare -a JOB_NODES=()
    declare -a JOB_CMDS=()
    declare -a JOB_PIDS=()
    declare -a JOB_LOGS=()
    declare -a JOB_LAST_LINE=()
    declare -a JOB_STATUS_LINE=()
    declare -a JOB_DONE=()
    declare -A JOB_INDEX_BY_NODE=()
    RENDERED_ONCE=0
    LIVE_CAN_REDRAW=0
    [ -t 1 ] && LIVE_CAN_REDRAW=1
    LIVE_TERM_COLS=$(tput cols 2>/dev/null)
    if ! [[ "$LIVE_TERM_COLS" =~ ^[0-9]+$ ]]; then
        LIVE_TERM_COLS=120
    fi
    LIVE_STATUS_WIDTH=$((LIVE_TERM_COLS - 6))
    if [ "$LIVE_STATUS_WIDTH" -lt 24 ]; then
        LIVE_STATUS_WIDTH=24
    fi

    sanitize_status_line() {
        local log_file="$1"
        tr '\r' '\n' < "$log_file" 2>/dev/null \
            | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' \
            | sed '/^[[:space:]]*$/d' \
            | awk 'END{print}'
    }

    format_status_line() {
        local text="$1"
        local max_len=90
        text="${text//$'\t'/ }"
        text="$(echo "$text" | sed -E 's/[[:space:]]+/ /g; s/^ +//; s/ +$//')"
        if [ "${#text}" -gt "$max_len" ]; then
            text="${text:0:$((max_len - 3))}..."
        fi
        echo "$text"
    }

    truncate_live_text() {
        local text="$1"
        local max_len="$2"
        if [ "${#text}" -gt "$max_len" ]; then
            text="${text:0:$((max_len - 3))}..."
        fi
        printf "%s" "$text"
    }

    render_status_table() {
        local i total_rows
        total_rows="${#JOB_NODES[@]}"
        if [ "$LIVE_CAN_REDRAW" -ne 1 ]; then
            return
        fi
        if [ "$RENDERED_ONCE" -eq 1 ]; then
            printf "\033[%dA" $((total_rows * 3 + 1))
        fi
        for i in "${!JOB_NODES[@]}"; do
            printf "  ${FARM_C_NODE}%s${FARM_C_RESET}\033[K\n" "${JOB_NODES[$i]}:"
            printf "    %s\033[K\n" \
                "$(truncate_live_text "${JOB_STATUS_LINE[$i]}" "$LIVE_STATUS_WIDTH")"
            printf "\033[K\n"
        done
        printf "  ${FARM_C_WARN}Press Enter to exit${FARM_C_RESET}\033[K\n"
        RENDERED_ONCE=1
    }

    # Build a unified node list first; only add command jobs for nodes that need work.
    for NODE in "${NODES[@]}"; do
        JOB_INDEX_BY_NODE[$NODE]="${#JOB_NODES[@]}"
        JOB_NODES+=("$NODE")
        JOB_CMDS+=("")
        JOB_STATUS_LINE+=("${WAKE_NODE_SUMMARY[$NODE]}")
    done

    for NODE in "${NODES[@]}"; do
        idx="${JOB_INDEX_BY_NODE[$NODE]}"
        if farm_is_dual_boot_node "$NODE"; then
            for NODE_DEF in "${DUAL_BOOT_NODES[@]}"; do
                IFS='|' read -r NAME BIOS_GUID LINUX_WAIT WIN_USER <<< "$NODE_DEF"
                if [ "$NAME" != "$NODE" ]; then
                    continue
                fi
                STATUS=${DUALBOOT_STATUS[$NAME]}
                if [ "$STATUS" -eq 0 ] || [ "$STATUS" -eq 1 ]; then
                    DUALBOOT_SCRIPT=$(make_dualboot_script "$NAME" "$BIOS_GUID" "$LINUX_WAIT" "$STATUS")
                    TMPFILE=$(mktemp /tmp/dualboot_${NAME}_XXXXXX.sh)
                    echo "$DUALBOOT_SCRIPT" > "$TMPFILE"
                    chmod +x "$TMPFILE"
                    JOB_CMDS[$idx]="bash \"$TMPFILE\"; rm -f \"$TMPFILE\""
                fi
                break
            done
        else
            if [ "${LINUX_STATUS[$NODE]}" = "offline" ]; then
                JOB_CMDS[$idx]="while ! ping -c 1 -W 1 \"$NODE\" >/dev/null 2>&1; do sleep 1; done; echo \"$NODE online and ready\""
            fi
        fi
    done

    echo "Wake node status (live):"
    echo ""
    tmp_status_dir=$(mktemp -d)
    for idx in "${!JOB_NODES[@]}"; do
        JOB_LOGS[$idx]="$tmp_status_dir/job_${idx}.log"
        : > "${JOB_LOGS[$idx]}"
        JOB_LAST_LINE[$idx]=""
        if [ -n "${JOB_CMDS[$idx]}" ]; then
            bash -lc "${JOB_CMDS[$idx]}" > "${JOB_LOGS[$idx]}" 2>&1 &
            JOB_PIDS[$idx]=$!
            if [ -n "${WAKE_NODE_SUMMARY[${JOB_NODES[$idx]}]}" ]; then
                JOB_STATUS_LINE[$idx]="${WAKE_NODE_SUMMARY[${JOB_NODES[$idx]}]} | running..."
            else
                JOB_STATUS_LINE[$idx]="cmd sent; running..."
            fi
            JOB_DONE[$idx]=0
        else
            JOB_PIDS[$idx]=""
            JOB_DONE[$idx]=1
        fi
    done
    if [ "$LIVE_CAN_REDRAW" -eq 1 ]; then
        render_status_table
    else
        for idx in "${!JOB_NODES[@]}"; do
            printf "  ${FARM_C_NODE}%s${FARM_C_RESET}\n" "${JOB_NODES[$idx]}:"
            printf "    %s\n" \
                "$(truncate_live_text "${JOB_STATUS_LINE[$idx]}" "$LIVE_STATUS_WIDTH")"
            echo ""
        done
    fi

    done_jobs=0
    target_jobs=0
    for idx in "${!JOB_NODES[@]}"; do
        if [ -n "${JOB_CMDS[$idx]}" ]; then
            target_jobs=$((target_jobs + 1))
        fi
    done

    # Background reader: sets a flag when Enter is pressed so the loop can exit early.
    _enter_flag=$(mktemp)
    ( IFS= read -r -s < /dev/tty; echo 1 > "$_enter_flag" ) &
    _enter_pid=$!

    while [ "$done_jobs" -lt "$target_jobs" ]; do
        # Exit early if user pressed Enter
        if [ -s "$_enter_flag" ]; then
            break
        fi

        done_jobs=0
        for idx in "${!JOB_PIDS[@]}"; do
            if [ -z "${JOB_CMDS[$idx]}" ]; then
                continue
            fi
            if [ "${JOB_DONE[$idx]}" -eq 1 ]; then
                done_jobs=$((done_jobs + 1))
                continue
            fi

            latest_line="$(sanitize_status_line "${JOB_LOGS[$idx]}")"
            if [ -n "$latest_line" ] && [ "$latest_line" != "${JOB_LAST_LINE[$idx]}" ]; then
                JOB_LAST_LINE[$idx]="$latest_line"
                JOB_STATUS_LINE[$idx]="cmd: $(format_status_line "$latest_line")"
                if [ "$LIVE_CAN_REDRAW" -ne 1 ]; then
                    printf "  ${FARM_C_NODE}%s${FARM_C_RESET}\n" "${JOB_NODES[$idx]}:"
                    printf "    %s\n" \
                        "$(truncate_live_text "${JOB_STATUS_LINE[$idx]}" "$LIVE_STATUS_WIDTH")"
                    echo ""
                fi
                render_status_table
            fi

            if ! kill -0 "${JOB_PIDS[$idx]}" 2>/dev/null; then
                wait "${JOB_PIDS[$idx]}" 2>/dev/null
                exit_code=$?
                JOB_DONE[$idx]=1
                done_jobs=$((done_jobs + 1))
                if [ "$exit_code" -eq 0 ]; then
                    JOB_STATUS_LINE[$idx]="cmd: done"
                else
                    JOB_STATUS_LINE[$idx]="cmd: failed (exit=$exit_code)"
                fi
                if [ "$LIVE_CAN_REDRAW" -ne 1 ]; then
                    printf "  ${FARM_C_NODE}%s${FARM_C_RESET}\n" "${JOB_NODES[$idx]}:"
                    printf "    %s\n" \
                        "$(truncate_live_text "${JOB_STATUS_LINE[$idx]}" "$LIVE_STATUS_WIDTH")"
                    echo ""
                fi
                render_status_table
            fi
        done
        sleep 0.2
    done

    kill "$_enter_pid" 2>/dev/null
    wait "$_enter_pid" 2>/dev/null
    rm -f "$_enter_flag"
    printf "\n\n"
    rm -rf "$tmp_status_dir"
else
    # --- MONITORING SCRIPT (Linux nodes) ---
    read -r -d '' MONITOR_SCRIPT << EOF
TARGET=\$1
echo "Warte auf Netzwerkverbindung zu \$TARGET..."
while ! ping -c 1 -W 1 "\$TARGET" &> /dev/null; do
    sleep 1
done
echo ""
echo -e "${FARM_C_OK}\$TARGET ist ONLINE und bereit!${FARM_C_RESET}"
sleep 5
EOF

    # --- ENCODING ---
    B64_MONITOR=$(echo "$MONITOR_SCRIPT" | base64 -w 0)
    CMD_TEMPLATE="echo $B64_MONITOR | base64 -d | bash -s"

    # --- TMUX SETUP ---
    farm_tmux_reset_session "$SESSION"

    # --- BUILD LINUX NODE LIST ---
    for NODE in "${NODES[@]}"; do
        if farm_is_dual_boot_node "$NODE"; then
            continue
        fi
        farm_tmux_add_pane "$SESSION" "$CMD_TEMPLATE $NODE" "NODE: $NODE"
    done

    # --- ADD DUAL BOOT NODES ---
    for NODE_DEF in "${DUAL_BOOT_NODES[@]}"; do
        IFS='|' read -r NAME BIOS_GUID LINUX_WAIT WIN_USER <<< "$NODE_DEF"
        STATUS=${DUALBOOT_STATUS[$NAME]}
        DUALBOOT_SCRIPT=$(make_dualboot_script "$NAME" "$BIOS_GUID" "$LINUX_WAIT" "$STATUS")
        TMPFILE=$(mktemp /tmp/dualboot_${NAME}_XXXXXX.sh)
        echo "$DUALBOOT_SCRIPT" > "$TMPFILE"
        chmod +x "$TMPFILE"
        farm_tmux_add_pane \
            "$SESSION" \
            "bash $TMPFILE; rm $TMPFILE" \
            "NODE: $NAME (dual-boot)"
    done

    # --- APPLY SHARED TMUX CONFIG ---
    farm_tmux_apply_config "$SESSION"

    # --- LAUNCH TERMINAL ---
    farm_launch_terminal \
        "farm-startup" "$X_START" "$SESSION" 1.0
fi