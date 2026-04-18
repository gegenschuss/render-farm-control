#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
cd "$(dirname "$0")"
source ../lib/config.sh
farm_require_bash4 "power_action.sh"

show_help() {
    local mode="$1"
    local script_name="./power_action.sh $mode"
    if [[ "$mode" == "shutdown" ]]; then
        cat << EOF
Usage: $script_name [options]

Shutdown eligible farm nodes with optional scheduling and safety checks.

Options:
  -h, --help          Show this help message
  -y, --yes           Auto-confirm prompts and continue
      --dry-run       Print planned actions without executing them
      --no-local      Do not shutdown local workstation
      --local         Include local workstation shutdown
      --delay=MIN     Schedule shutdown after MIN minutes
      --force         Override security gate (update activity)
EOF
    else
        cat << EOF
Usage: $script_name [options]

Reboot eligible farm nodes with dual-boot awareness and health checks.

Options:
  -h, --help      Show this help message
  -y, --yes       Auto-confirm prompts and continue
      --dry-run   Print planned actions without executing them
      --no-local  Do not reboot local workstation
      --local     Include local workstation reboot
      --force     Override security gate (update activity)
      --windows-only
                  Reboot only dual-boot nodes currently on Windows
EOF
    fi
}

MODE="${1:-}"
if [[ -z "$MODE" || "$MODE" == "-h" || "$MODE" == "--help" ]]; then
    echo "Usage: ./power_action.sh <shutdown|reboot> [options]"
    exit 0
fi
shift

AUTO_YES=0
DRY_RUN=0
NO_LOCAL=0
WITH_LOCAL=0
FORCE_ACTION=0
DELAY_OVERRIDE=""
POSTJOB=0
WINDOWS_ONLY=0

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            show_help "$MODE"
            exit 0
            ;;
        --yes|-y) AUTO_YES=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --no-local) NO_LOCAL=1 ;;
        --local) WITH_LOCAL=1 ;;
        --force) FORCE_ACTION=1 ;;
        --windows-only)
            if [[ "$MODE" != "reboot" ]]; then
                farm_print_error "--windows-only is reboot-only"
                exit 1
            fi
            WINDOWS_ONLY=1
            ;;
        --delay=*) DELAY_OVERRIDE="${arg#*=}" ;;
        --postjob)
            if [[ "$MODE" != "shutdown" ]]; then
                farm_print_error "--postjob is shutdown-only"
                exit 1
            fi
            POSTJOB=1
            ;;
        *) farm_print_error "Unknown option: $arg"; exit 1 ;;
    esac
done

if [ "$POSTJOB" -eq 1 ]; then
    farm_disable_colors
fi

prompt_inline_yn_with_cancel() {
    local prompt_text="$1"
    local answer
    printf "%s (y/n)? " "$prompt_text"
    read -n 1 -s -r answer
    echo "$answer"
    if [[ "$answer" == "q" || "$answer" == "Q" ]]; then
        echo "Aborted."
        exit 0
    fi
    FARM_PROMPT_ANSWER="$answer"
}

prompt_inline_choice_with_cancel() {
    local prompt_text="$1"
    local answer
    printf "%s " "$prompt_text"
    read -n 1 -s -r answer
    echo "$answer"
    if [[ "$answer" == "q" || "$answer" == "Q" ]]; then
        echo "Aborted."
        exit 0
    fi
    FARM_PROMPT_ANSWER="$answer"
}

CHECK_SPINNER='|/-\'
CHECK_SPINNER_IDX=0
CHECK_TOTAL=0
CHECK_DONE=0
CHECK_PROGRESS_SUPPRESS_FINISH=0
RUN_NO_TMUX_UI=0
if [[ "${FARM_OS:-linux}" == "linux" || "${FARM_OS:-linux}" == "mac" ]]; then
    if [ "${FARM_USE_TMUX_UI:-0}" -ne 1 ]; then
        RUN_NO_TMUX_UI=1
    fi
fi

start_check_progress() {
    CHECK_TOTAL="$1"
    CHECK_DONE=0
}

show_check_progress() {
    local current_node="$1"
    local spin_char
    spin_char="${CHECK_SPINNER:$CHECK_SPINNER_IDX:1}"
    printf "\r  ${FARM_C_WARN}Checking nodes${FARM_C_RESET} %s [%d/%d]  %-14s\033[K" \
        "$spin_char" "$CHECK_DONE" "$CHECK_TOTAL" "$current_node"
    CHECK_SPINNER_IDX=$(((CHECK_SPINNER_IDX + 1) % 4))
}

complete_check_progress_step() {
    CHECK_DONE=$((CHECK_DONE + 1))
    printf "\r\033[K"
}

finish_check_progress() {
    if [ "${CHECK_TOTAL:-0}" -gt 0 ]; then
        if [ "${CHECK_PROGRESS_SUPPRESS_FINISH:-0}" -eq 1 ]; then
            printf "\r\033[K"
        else
            printf "\r  ${FARM_C_WARN}Checking nodes${FARM_C_RESET} ${FARM_C_OK}[DONE]${FARM_C_RESET} [%d/%d]\033[K\n" \
                "$CHECK_TOTAL" "$CHECK_TOTAL"
        fi
    fi
}

truncate_table_text() {
    local text="$1"
    local max_len="$2"
    if [ "${#text}" -gt "$max_len" ]; then
        text="${text:0:$((max_len - 3))}..."
    fi
    printf "%s" "$text"
}

run_commands_with_live_status() {
    local title="$1"
    local nodes_ref="$2"
    local cmds_ref="$3"
    declare -n status_nodes="$nodes_ref"
    declare -n status_cmds="$cmds_ref"

    local total done_count idx exit_code latest_line
    local term_cols table_status_width
    local tmp_dir
    local -a pids=()
    local -a done_map=()
    local -a logs=()
    local -a last_line=()
    local -a status_lines=()
    local rendered_once=0
    local can_redraw=0
    local spinner_chars='|/-\'
    local spinner_idx=0
    local spin_char
    local any_failed=0

    format_status_text() {
        local text="$1"
        local max_len=90
        text="${text//$'\t'/ }"
        text="$(echo "$text" | sed -E 's/[[:space:]]+/ /g; s/^ +//; s/ +$//')"
        if [ "${#text}" -gt "$max_len" ]; then
            text="${text:0:$((max_len - 3))}..."
        fi
        echo "$text"
    }

    sanitize_status_line() {
        local log_file="$1"
        tr '\r' '\n' < "$log_file" 2>/dev/null \
            | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' \
            | sed '/^[[:space:]]*$/d' \
            | awk 'END{print}'
    }

    render_status_table() {
        local i
        if [ "$can_redraw" -ne 1 ]; then
            return
        fi
        if [ "$rendered_once" -eq 1 ]; then
            printf "\033[%dA" $((total * 3 + 1))
        fi
        for i in "${!status_nodes[@]}"; do
            printf "  ${FARM_C_NODE}%s${FARM_C_RESET}\033[K\n" "${status_nodes[$i]}:"
            printf "    %s\033[K\n" \
                "$(truncate_table_text "${status_lines[$i]}" "$table_status_width")"
            printf "\033[K\n"
        done
        printf "  ${FARM_C_WARN}Press Enter to exit${FARM_C_RESET}\033[K\n"
        rendered_once=1
    }

    total="${#status_nodes[@]}"
    if [ "$total" -eq 0 ]; then
        RUN_STATUS_FAILED=0
        return 0
    fi
    [ -t 1 ] && can_redraw=1
    term_cols=$(tput cols 2>/dev/null)
    if ! [[ "$term_cols" =~ ^[0-9]+$ ]]; then
        term_cols=120
    fi
    table_status_width=$((term_cols - 6))
    if [ "$table_status_width" -lt 24 ]; then
        table_status_width=24
    fi

    echo "$title"
    tmp_dir=$(mktemp -d)

    for idx in "${!status_nodes[@]}"; do
        logs[$idx]="$tmp_dir/node_${idx}.log"
        : > "${logs[$idx]}"
        bash -lc "${status_cmds[$idx]}" > "${logs[$idx]}" 2>&1 &
        pids[$idx]=$!
        done_map[$idx]=0
        last_line[$idx]=""
        status_lines[$idx]="running..."
    done
    if [ "$can_redraw" -eq 1 ]; then
        render_status_table
    else
        for idx in "${!status_nodes[@]}"; do
            printf "  ${FARM_C_NODE}%s${FARM_C_RESET}\n" "${status_nodes[$idx]}:"
            printf "    %s\n" \
                "$(truncate_table_text "${status_lines[$idx]}" "$table_status_width")"
            echo ""
        done
    fi

    local _enter_flag
    _enter_flag=$(mktemp)
    ( IFS= read -r -s < /dev/tty; echo 1 > "$_enter_flag" ) &
    local _enter_pid=$!

    done_count=0
    while [ "$done_count" -lt "$total" ]; do
        if [ -s "$_enter_flag" ]; then break; fi
        done_count=0
        spin_char="${spinner_chars:$spinner_idx:1}"
        spinner_idx=$(((spinner_idx + 1) % 4))
        for idx in "${!pids[@]}"; do
            if [ "${done_map[$idx]}" -eq 1 ]; then
                done_count=$((done_count + 1))
                continue
            fi

            latest_line="$(sanitize_status_line "${logs[$idx]}")"
            if [ -n "$latest_line" ] && [ "$latest_line" != "${last_line[$idx]}" ]; then
                last_line[$idx]="$latest_line"
                status_lines[$idx]="$(format_status_text "$latest_line")"
                if [ "$can_redraw" -ne 1 ]; then
                    printf "  ${FARM_C_NODE}%s${FARM_C_RESET}\n" "${status_nodes[$idx]}:"
                    printf "    %s\n" \
                        "$(truncate_table_text "${status_lines[$idx]}" "$table_status_width")"
                    echo ""
                fi
                render_status_table
            elif [ -z "${last_line[$idx]}" ]; then
                status_lines[$idx]="running $spin_char"
            fi

            if ! kill -0 "${pids[$idx]}" 2>/dev/null; then
                wait "${pids[$idx]}" 2>/dev/null
                exit_code=$?
                done_map[$idx]=1
                done_count=$((done_count + 1))
                if [ "$exit_code" -eq 0 ]; then
                    status_lines[$idx]="done"
                else
                    status_lines[$idx]="failed (exit=$exit_code)"
                    any_failed=1
                fi
                if [ "$can_redraw" -ne 1 ]; then
                    printf "  ${FARM_C_NODE}%s${FARM_C_RESET}\n" "${status_nodes[$idx]}:"
                    printf "    %s\n" \
                        "$(truncate_table_text "${status_lines[$idx]}" "$table_status_width")"
                    echo ""
                fi
                render_status_table
            fi
        done
        render_status_table
        sleep 0.15
    done

    kill "$_enter_pid" 2>/dev/null
    wait "$_enter_pid" 2>/dev/null
    rm -f "$_enter_flag"
    printf "\n\n"

    rm -rf "$tmp_dir"
    RUN_STATUS_FAILED="$any_failed"
    return 0
}

run_shutdown() {
    local X_START="$FARM_X_START"
    local SESSION="farm_shutdown"
    local local_choice schedule_choice delay_minutes
    local -a SHUTDOWN_NODES=()
    local -A SEEN_NODES=()

    [ "$FORCE_ACTION" -eq 1 ] && farm_print_warn "WARNING: --force active — skipping update/activity safety checks."

    # Build ordered node list (NODES + any extra dual-boot nodes not already listed).
    for NODE in "${NODES[@]}"; do
        SHUTDOWN_NODES+=("$NODE")
        SEEN_NODES["$NODE"]=1
    done
    for NODE_DEF in "${DUAL_BOOT_NODES[@]}"; do
        IFS='|' read -r NAME _ _ _ <<< "$NODE_DEF"
        [[ -z "${SEEN_NODES[$NAME]+x}" ]] && SHUTDOWN_NODES+=("$NAME") && SEEN_NODES["$NAME"]=1
    done

    disable_autowake_timer() {
        if [ -x "$SCRIPTS/deadline/autowake.sh" ]; then
            bash "$SCRIPTS/deadline/autowake.sh" disable >/dev/null 2>&1 || true
        fi
    }

    local_shutdown_countdown() {
        local seconds="${1:-10}"
        echo "Shutting down local machine soon..."
        echo ""
        if ! farm_countdown_with_pause "$seconds" "Local shutdown in"; then
            farm_print_warn "Local shutdown cancelled by user. Remote node shutdown continues."
            echo ""
            return 1
        fi
        return 0
    }

    # ── POSTJOB path (non-interactive, no live table) ────────────────
    if [ "$POSTJOB" -eq 1 ]; then
        farm_print_title "FARM SHUTDOWN (POST-JOB)"
        echo "Running non-interactive post-job shutdown mode..."
        echo ""

        local -a target_nodes=()
        local -a _pids=() _sfiles=()
        local _tmp; _tmp=$(mktemp -d)
        for idx in "${!SHUTDOWN_NODES[@]}"; do
            node="${SHUTDOWN_NODES[$idx]}"
            _sfiles[$idx]="$_tmp/s${idx}"
            ( farm_get_node_os_status "$node" "ssh"; printf "%d\n" "$?" > "${_sfiles[$idx]}" ) &
            _pids[$idx]=$!
        done
        for pid in "${_pids[@]}"; do wait "$pid" 2>/dev/null; done
        local -A _postjob_os=()
        for idx in "${!SHUTDOWN_NODES[@]}"; do
            IFS= read -r _postjob_os["${SHUTDOWN_NODES[$idx]}"] < "${_sfiles[$idx]}" 2>/dev/null || _postjob_os["${SHUTDOWN_NODES[$idx]}"]=0
        done
        rm -rf "$_tmp"

        for NODE in "${SHUTDOWN_NODES[@]}"; do
            case ${_postjob_os[$NODE]} in
                2)
                    if [ "$FORCE_ACTION" -eq 1 ] || check_update_blockers "$NODE"; then
                        target_nodes+=("$NODE")
                        echo "$(farm_node_tag "$NODE") Linux - queued for shutdown"
                    else
                        echo "$(farm_node_tag "$NODE") Linux - BLOCKED (update activity detected)"
                    fi
                    ;;
                1) echo "$(farm_node_tag "$NODE") Windows - skipped" ;;
                0) echo "$(farm_node_tag "$NODE") offline - skipped" ;;
            esac
        done
        [ "$WITH_LOCAL" -eq 1 ] && echo "$(farm_node_tag "$FARM_LOCAL_NAME") local - queued for shutdown"

        if [ ${#target_nodes[@]} -eq 0 ] && [ "$WITH_LOCAL" -eq 0 ]; then
            farm_print_ok "No eligible Linux nodes to shutdown."
            exit 0
        fi

        if [ "$DRY_RUN" -eq 1 ]; then
            echo ""
            local dry_count=${#target_nodes[@]}
            [ "$WITH_LOCAL" -eq 1 ] && ((dry_count++))
            echo -e "${FARM_C_WARN}[dry-run]${FARM_C_RESET} Would send shutdown command to ${dry_count} node(s):"
            for NODE in "${target_nodes[@]}"; do echo "  - $NODE"; done
            [ "$WITH_LOCAL" -eq 1 ] && echo "  - $FARM_LOCAL_NAME (local)"
            farm_print_ok "Dry-run complete. No changes were made."
            exit 0
        fi

        echo ""
        echo "Sending shutdown command to ${#target_nodes[@]} node(s)..."
        disable_autowake_timer
        for NODE in "${target_nodes[@]}"; do
            farm_ssh_batch -o ConnectTimeout=5 "$NODE" "$FARM_REMOTE_SHUTDOWN_CMD" >/dev/null 2>&1 &
        done
        wait
        farm_print_ok "Post-job shutdown commands sent."
        if [ "$WITH_LOCAL" -eq 1 ]; then
            echo "Shutting down local workstation ($FARM_LOCAL_NAME) in 1 minute..."
            wall "REMOTE SHUTDOWN: $FARM_LOCAL_NAME will power off in 1 minute." 2>/dev/null || true
            DISPLAY="${DISPLAY:-:0}" \
            XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}" \
            zenity --warning --title="Remote Shutdown" \
                --text="$FARM_LOCAL_NAME will shut down in 1 minute (triggered remotely)." \
                --timeout=55 &>/dev/null &
            sudo -n shutdown -h +1 &>/dev/null
        fi
        exit 0
    fi

    # ── interactive path ──────────────────────────────────────────────────────
    "$FARM_SCRIPTS_DIR/lib/header.sh"
    echo ""
    farm_print_title "FARM SHUTDOWN"

    if [ "$WITH_LOCAL" -eq 1 ]; then local_choice="y"; else local_choice="n"; fi

    # Schedule prompt (before live table so user configures timing first).
    if [ -n "$DELAY_OVERRIDE" ]; then
        schedule_choice="y"
    elif [ "$AUTO_YES" -eq 1 ]; then
        schedule_choice="n"
    else
        echo ""
        prompt_inline_yn_with_cancel "Schedule for later"
        schedule_choice="$FARM_PROMPT_ANSWER"
        farm_prompt_rule
    fi

    delay_minutes=0
    if [[ "$schedule_choice" =~ ^[Yy]$ ]]; then
        if [ -n "$DELAY_OVERRIDE" ]; then
            delay_minutes="$DELAY_OVERRIDE"
        elif [ "$AUTO_YES" -eq 1 ]; then
            delay_minutes=0
        else
            read -r -p "Enter delay in minutes: " delay_minutes
            if [[ "$delay_minutes" == "q" || "$delay_minutes" == "Q" ]]; then
                echo "Aborted."; exit 0
            fi
        fi
        if [[ ! "$delay_minutes" =~ ^[0-9]+$ ]]; then
            farm_print_error "Invalid delay value. Please enter a number."
            exit 1
        fi
        echo ""
    fi

    # Include local in the table if requested.
    local -a TABLE_NODES=("${SHUTDOWN_NODES[@]}")
    [[ "$local_choice" =~ ^[Yy]$ ]] && TABLE_NODES+=("$FARM_LOCAL_NAME")
    local total_nodes="${#TABLE_NODES[@]}"

    # ── terminal ──────────────────────────────────────────────────────────────
    local can_redraw=0 term_cols table_w
    [ -t 1 ] && can_redraw=1
    term_cols=$(tput cols 2>/dev/null)
    [[ "$term_cols" =~ ^[0-9]+$ ]] || term_cols=120
    table_w=$(( term_cols - 6 )); [ "$table_w" -lt 24 ] && table_w=24

    # ── per-node state ────────────────────────────────────────────────────────
    local -a TBL_STATUS=() RES_CMD=()
    local i
    for i in "${!TABLE_NODES[@]}"; do
        TBL_STATUS[$i]="checking..."
        RES_CMD[$i]=""
    done

    # ── table renderer ────────────────────────────────────────────────────────
    local _tbl_drawn=0 _tbl_footer_lines=0
    _draw_table() {
        local footer="${1:-}"
        if [ "$can_redraw" -eq 1 ] && [ "$_tbl_drawn" -eq 1 ]; then
            printf "\033[%dA" $(( total_nodes * 3 + _tbl_footer_lines ))
        fi
        for i in "${!TABLE_NODES[@]}"; do
            printf "  ${FARM_C_NODE}%s${FARM_C_RESET}\033[K\n" "${TABLE_NODES[$i]}:"
            printf "    %s\033[K\n" \
                "$(truncate_table_text "${TBL_STATUS[$i]}" "$table_w")"
            printf "\033[K\n"
        done
        _tbl_footer_lines=0
        if [ -n "$footer" ]; then
            printf "  %s\033[K\n" "$footer"
            _tbl_footer_lines=1
        fi
        _tbl_drawn=1
    }

    # ── remote shutdown payload ───────────────────────────────────────────────
    local REMOTE_SCRIPT B64_PAYLOAD FINAL_CMD
    read -r -d '' REMOTE_SCRIPT << 'EOF'
echo ""
echo "Killing Houdini render processes (husk/mantra)..."
pkill -KILL -x husk   2>/dev/null && echo "  husk killed"   || echo "  husk: none"
pkill -KILL -x mantra 2>/dev/null && echo "  mantra killed" || echo "  mantra: none"
echo ""
echo "Gute Nacht. Powering off..."
sudo poweroff
EOF
    B64_PAYLOAD=$(echo "$REMOTE_SCRIPT" | base64 -w 0)
    FINAL_CMD="echo $B64_PAYLOAD | base64 -d | bash"

    # ── initial table render ──────────────────────────────────────────────────
    echo ""
    _draw_table "Checking... [0/$total_nodes]"

    # ── parallel check phase ──────────────────────────────────────────────────
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local -a _cpids=() _stat=() _cmd_f=() _done=()

    for i in "${!TABLE_NODES[@]}"; do
        local node="${TABLE_NODES[$i]}"
        _stat[$i]="$tmp_dir/s${i}"
        _cmd_f[$i]="$tmp_dir/c${i}"
        _done[$i]=0

        if [[ "$node" == "$FARM_LOCAL_NAME" ]]; then
            printf 'local - will shut down after remotes\n' > "${_stat[$i]}"
            printf 'local_shutdown\n'                       > "${_cmd_f[$i]}"
            _done[$i]=1
            continue
        fi

        (
            printf 'detecting OS...\n' > "${_stat[$i]}"
            farm_get_node_os_status "$node" "ssh_or_ping"
            local os=$?

            if [ "$os" -eq 0 ]; then
                printf 'offline - skipped\n' > "${_stat[$i]}"
                printf 'skip\n'              > "${_cmd_f[$i]}"
                exit 0
            fi

            if [ "$os" -eq 1 ]; then
                printf 'Windows - skipped\n' > "${_stat[$i]}"
                printf 'skip\n'              > "${_cmd_f[$i]}"
                exit 0
            fi

            # Linux (os == 2)
            printf 'Linux - checking blockers...\n' > "${_stat[$i]}"
            local blocked=0
            if [ "$FORCE_ACTION" -ne 1 ] && ! check_update_blockers "$node"; then
                blocked=1
            fi
            if [ "$blocked" -eq 1 ]; then
                printf 'Linux - BLOCKED (update activity)\n' > "${_stat[$i]}"
                printf 'blocked\n'                           > "${_cmd_f[$i]}"
                exit 0
            fi

            printf 'Linux - checking health...\n' > "${_stat[$i]}"
            check_linux_node_health "$node" > /dev/null 2>&1
            local health=$?

            local node_cmd="ssh -t -F ~/.ssh/config -o LogLevel=ERROR $node \"$FINAL_CMD\" ; sleep 3"
            if [ "$health" -eq 1 ]; then
                printf 'Linux - WARNING: active processes\n' > "${_stat[$i]}"
            else
                printf 'Linux - will shut down\n'           > "${_stat[$i]}"
            fi
            printf '%s\n' "$node_cmd" > "${_cmd_f[$i]}"
        ) &
        _cpids[$i]=$!
    done

    # ── poll loop ─────────────────────────────────────────────────────────────
    local _done_count=0 _sidx=0 _sc='|/-\' _sc_char
    while [ "$_done_count" -lt "$total_nodes" ]; do
        _done_count=0
        _sc_char="${_sc:$_sidx:1}"; _sidx=$(( (_sidx + 1) % 4 ))
        for i in "${!TABLE_NODES[@]}"; do
            if [ "${_done[$i]}" -eq 1 ]; then
                (( _done_count++ )); continue
            fi
            if [ -s "${_stat[$i]}" ]; then
                IFS= read -r TBL_STATUS[$i] < "${_stat[$i]}"
            else
                TBL_STATUS[$i]="checking... $_sc_char"
            fi
            if ! kill -0 "${_cpids[$i]}" 2>/dev/null; then
                wait "${_cpids[$i]}" 2>/dev/null
                _done[$i]=1; (( _done_count++ ))
                [ -s "${_stat[$i]}"  ] && IFS= read -r TBL_STATUS[$i] < "${_stat[$i]}"
                [ -s "${_cmd_f[$i]}" ] && IFS= read -r RES_CMD[$i]    < "${_cmd_f[$i]}"
            fi
        done
        _draw_table "Checking... [$_done_count/$total_nodes]"
        sleep 0.1
    done

    # Final result read for all nodes.
    for i in "${!TABLE_NODES[@]}"; do
        [ -s "${_stat[$i]}"  ] && IFS= read -r TBL_STATUS[$i] < "${_stat[$i]}"
        [ -s "${_cmd_f[$i]}" ] && IFS= read -r RES_CMD[$i]    < "${_cmd_f[$i]}"
    done
    rm -rf "$tmp_dir"

    # ── tally outcomes ────────────────────────────────────────────────────────
    local _n_will=0 _n_skip=0
    local -a BLOCKED_NODES=()
    for i in "${!TABLE_NODES[@]}"; do
        case "${RES_CMD[$i]}" in
            skip|"") (( _n_skip++ )) ;;
            blocked) (( _n_skip++ )); BLOCKED_NODES+=("${TABLE_NODES[$i]}") ;;
            *)       (( _n_will++ )) ;;
        esac
    done

    # ── confirm (inline footer) ───────────────────────────────────────────────
    local _summary="${_n_will} queued${_n_skip:+, ${_n_skip} skipped}"
    [ "${#BLOCKED_NODES[@]}" -gt 0 ] && _summary+=" — BLOCKED: ${BLOCKED_NODES[*]}"

    if [ "$AUTO_YES" -eq 0 ] && [ "$can_redraw" -eq 1 ]; then
        _draw_table "${_summary} — Proceed? [y/N]:"
        local _conf
        IFS= read -r -n 1 -s _conf < /dev/tty
        if [[ "$_conf" =~ ^[Yy]$ ]]; then
            printf "\033[%dA\r" $(( total_nodes * 3 + 1 ))
        else
            echo ""; echo "Aborted."; exit 0
        fi
    else
        _draw_table "$_summary"
        if ! farm_confirm_yn "Are you sure? (y/n): " "$AUTO_YES" "n"; then
            echo "Aborted."; exit 0
        fi
        if [ "$AUTO_YES" -eq 1 ] && [ "$can_redraw" -eq 1 ]; then
            printf "\033[%dA\r" $(( total_nodes * 3 + 1 ))
        else
            echo ""
        fi
    fi

    # ── security gate ─────────────────────────────────────────────────────────
    if [ "${#BLOCKED_NODES[@]}" -gt 0 ] && [ "$FORCE_ACTION" -ne 1 ]; then
        farm_print_error "Security stop: update-related activity detected."
        echo "Blocked node(s):"
        for node in "${BLOCKED_NODES[@]}"; do echo "  - $node"; done
        echo ""
        echo "Resolve updates first or rerun with --force to override."
        exit 1
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        farm_print_ok "Dry-run complete. No changes were made."
        echo ""
        exit 0
    fi

    # ── delay countdown (if scheduled) ───────────────────────────────────────
    if [[ "$schedule_choice" =~ ^[Yy]$ ]]; then
        echo "Waiting $delay_minutes minutes..."
        echo ""
        if ! farm_countdown_with_pause $((delay_minutes * 60)) "Shutdown in"; then
            echo "Shutdown cancelled. Exiting."
            exit 0
        fi
        echo ""
    fi

    # ── build exec arrays (ALL nodes so exec table height matches check table) ─
    local -a shutdown_exec_nodes=() shutdown_exec_cmds=()
    for i in "${!TABLE_NODES[@]}"; do
        local node="${TABLE_NODES[$i]}"
        local cmd="${RES_CMD[$i]}"
        shutdown_exec_nodes+=("$node")
        case "$cmd" in
            skip|blocked|"")
                shutdown_exec_cmds+=("true") ;;
            local_shutdown)
                shutdown_exec_cmds+=("echo 'local shutdown queued (follows after remotes)'; sleep 3") ;;
            *)
                shutdown_exec_cmds+=("$cmd") ;;
        esac
    done

    # Count actual remote targets (for local-only messaging).
    local remote_targets=0
    for i in "${!TABLE_NODES[@]}"; do
        local node="${TABLE_NODES[$i]}"
        [[ "$node" == "$FARM_LOCAL_NAME" ]] && continue
        case "${RES_CMD[$i]}" in skip|blocked|"") ;; *) ((remote_targets++)) ;; esac
    done

    # ── execute ───────────────────────────────────────────────────────────────
    if [ "$RUN_NO_TMUX_UI" -eq 1 ]; then
        disable_autowake_timer
        run_commands_with_live_status \
            "Executing remote shutdown commands..." \
            shutdown_exec_nodes shutdown_exec_cmds
    else
        farm_tmux_reset_session "$SESSION"
        for idx in "${!shutdown_exec_nodes[@]}"; do
            local n="${shutdown_exec_nodes[$idx]}"
            local c="${shutdown_exec_cmds[$idx]}"
            farm_tmux_add_pane "$SESSION" "$c" "NODE: $n"
        done
        farm_tmux_apply_config "$SESSION"
        farm_launch_terminal "farm-shutdown" "$X_START" "$SESSION" 1.0
    fi

    # ── local machine shutdown (after remotes) ────────────────────────────────
    if [[ "$local_choice" =~ ^[Yy]$ ]]; then
        if [ "$remote_targets" -eq 0 ]; then
            echo ""
            echo "No eligible remote Linux nodes to shut down."
            echo ""
        fi
        if local_shutdown_countdown 10; then
            disable_autowake_timer
            setsid bash -c 'sleep 3 && sudo poweroff' &>/dev/null &
            echo "Shutdown command sent. Powering off in ~3 seconds..."
        else
            echo ""
            echo "Local machine stays on."
            echo ""
        fi
    else
        if [ "$remote_targets" -gt 0 ]; then
            echo "Node shutdown sent. Local machine stays on."
        else
            echo "No eligible remote Linux nodes to shut down. Local machine stays on."
        fi
        echo ""
    fi
}

run_reboot() {
    local X_START="$FARM_X_START"
    local SESSION="farm_reboot"
    local local_choice reboot_scope_choice

    [ "$FORCE_ACTION" -eq 1 ] && \
        farm_print_warn "WARNING: --force active — skipping update/activity safety checks."
    "$FARM_SCRIPTS_DIR/lib/header.sh"
    echo ""
    farm_print_title "FARM REBOOT"

    if [ "$WITH_LOCAL" -eq 1 ]; then local_choice="y"; else local_choice="n"; fi
    echo ""

    if [ "$WINDOWS_ONLY" -eq 0 ]; then
        if [ "$AUTO_YES" -eq 1 ]; then
            reboot_scope_choice="a"
        else
            prompt_inline_choice_with_cancel \
                "[a] all nodes   [w] Win → Linux only"
            reboot_scope_choice="$FARM_PROMPT_ANSWER"
            farm_prompt_rule
        fi
        [[ "$reboot_scope_choice" =~ ^[Ww]$ ]] && WINDOWS_ONLY=1
    fi

    farm_init_dual_boot_names

    # ── ordered node list (identical for check + exec phases) ────────────────
    local -a TABLE_NODES=("${NODES[@]}")
    [[ "$local_choice" =~ ^[Yy]$ ]] && TABLE_NODES+=("$FARM_LOCAL_NAME")
    local total_nodes="${#TABLE_NODES[@]}"

    # ── terminal ──────────────────────────────────────────────────────────────
    local can_redraw=0 term_cols table_w
    [ -t 1 ] && can_redraw=1
    term_cols=$(tput cols 2>/dev/null)
    [[ "$term_cols" =~ ^[0-9]+$ ]] || term_cols=120
    table_w=$(( term_cols - 6 )); [ "$table_w" -lt 24 ] && table_w=24

    # ── per-node state ────────────────────────────────────────────────────────
    # TBL_STATUS : display text shown in the table for each node
    # RES_CMD    : exec command: "skip" | "blocked" | "local_reboot"
    #              | "win_reboot:<BIOS_GUID>" | <ssh-cmd>
    local -a TBL_STATUS=() RES_CMD=()
    local i
    for i in "${!TABLE_NODES[@]}"; do
        TBL_STATUS[$i]="checking..."
        RES_CMD[$i]=""
    done

    # ── table renderer ────────────────────────────────────────────────────────
    # _draw_table [footer-text]
    # Redraws in-place on every call after the first.
    # Tracks _tbl_drawn / _tbl_footer_lines for accurate cursor-up math.
    local _tbl_drawn=0 _tbl_footer_lines=0
    _draw_table() {
        local footer="${1:-}"
        if [ "$can_redraw" -eq 1 ] && [ "$_tbl_drawn" -eq 1 ]; then
            printf "\033[%dA" $(( total_nodes * 3 + _tbl_footer_lines ))
        fi
        for i in "${!TABLE_NODES[@]}"; do
            printf "  ${FARM_C_NODE}%s${FARM_C_RESET}\033[K\n" "${TABLE_NODES[$i]}:"
            printf "    %s\033[K\n" \
                "$(truncate_table_text "${TBL_STATUS[$i]}" "$table_w")"
            printf "\033[K\n"
        done
        _tbl_footer_lines=0
        if [ -n "$footer" ]; then
            printf "  %s\033[K\n" "$footer"
            _tbl_footer_lines=1
        fi
        _tbl_drawn=1
    }

    # ── dualboot reboot script builder (must be defined before subshells) ─────
    make_dualboot_reboot_script() {
        local NAME=$1 BIOS_GUID=$2
        cat << EOF
echo "[$NAME] Setting boot target to Linux via efibootmgr..."
LINUX_ENTRY=\$(ssh -F ~/.ssh/config -o LogLevel=ERROR $NAME "efibootmgr | grep -i ubuntu | grep -oP '(?<=Boot)\d{4}' | head -1" 2>/dev/null)
if [ -z "\$LINUX_ENTRY" ]; then
    echo "[$NAME] Could not find Linux EFI entry - rebooting without setting boot target"
else
    ssh -F ~/.ssh/config -o LogLevel=ERROR $NAME "sudo efibootmgr --bootnext \$LINUX_ENTRY" 2>/dev/null
    echo "[$NAME] Boot target set to entry: \$LINUX_ENTRY"
fi
echo "[$NAME] Killing Houdini render processes (husk/mantra)..."
ssh -F ~/.ssh/config -o LogLevel=ERROR $NAME "pkill -KILL -x husk 2>/dev/null && echo '  husk killed' || echo '  husk: none'; pkill -KILL -x mantra 2>/dev/null && echo '  mantra killed' || echo '  mantra: none'"
echo "[$NAME] Rebooting..."
ssh -F ~/.ssh/config -o LogLevel=ERROR $NAME "systemctl reboot"
echo ""
echo -e "${FARM_C_OK}$NAME: rebooting to Linux...${FARM_C_RESET}"
sleep 3
EOF
    }

    local CMD_SSH_REBOOT
    CMD_SSH_REBOOT="echo ''; echo '------------------------------'; echo 'REBOOT INITIATED'; echo '------------------------------'; echo 'Killing Houdini render processes (husk/mantra)...'; pkill -KILL -x husk 2>/dev/null && echo '  husk killed' || echo '  husk: none'; pkill -KILL -x mantra 2>/dev/null && echo '  mantra killed' || echo '  mantra: none'; echo 'Reboot in 2...'; sleep 1; echo 'Reboot in 1...'; sleep 1; echo 'See you on the other side.'; systemctl reboot"

    # ── initial table render ──────────────────────────────────────────────────
    echo ""
    _draw_table "Checking... [0/$total_nodes]"

    # ── parallel check phase ──────────────────────────────────────────────────
    # Each background subshell writes its current status text to a .stat file
    # (overwritten on each update) and its final exec command to a .cmd file.
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local -a _cpids=() _stat=() _cmd_f=() _done=()

    for i in "${!TABLE_NODES[@]}"; do
        local node="${TABLE_NODES[$i]}"
        _stat[$i]="$tmp_dir/s${i}"
        _cmd_f[$i]="$tmp_dir/c${i}"
        _done[$i]=0

        # Local machine requires no network check.
        if [[ "$node" == "$FARM_LOCAL_NAME" ]]; then
            printf 'local - will reboot after remotes\n' > "${_stat[$i]}"
            printf 'local_reboot\n'                      > "${_cmd_f[$i]}"
            _done[$i]=1
            continue
        fi

        # Background per-node full check ──────────────────────────────────────
        (
            printf 'detecting OS...\n' > "${_stat[$i]}"
            farm_get_node_os_status "$node" "ssh_or_ping"
            local os=$?

            # offline
            if [ "$os" -eq 0 ]; then
                printf 'offline - skipped\n' > "${_stat[$i]}"
                printf 'skip\n'              > "${_cmd_f[$i]}"
                exit 0
            fi

            # Windows
            if [ "$os" -eq 1 ]; then
                if [ "$WINDOWS_ONLY" -eq 1 ] && farm_is_dual_boot_node "$node"; then
                    local _bios="" _def _n _b _lw _wu
                    for _def in "${DUAL_BOOT_NODES[@]}"; do
                        IFS='|' read -r _n _b _lw _wu <<< "$_def"
                        [[ "$_n" == "$node" ]] && _bios="$_b" && break
                    done
                    printf 'Windows - will reboot to Linux\n' > "${_stat[$i]}"
                    printf 'win_reboot:%s\n' "$_bios"        > "${_cmd_f[$i]}"
                else
                    printf 'Windows - skipped\n' > "${_stat[$i]}"
                    printf 'skip\n'              > "${_cmd_f[$i]}"
                fi
                exit 0
            fi

            # Linux (os == 2)
            if [ "$WINDOWS_ONLY" -eq 1 ]; then
                printf 'Linux - skipped (--windows-only)\n' > "${_stat[$i]}"
                printf 'skip\n'                             > "${_cmd_f[$i]}"
                exit 0
            fi

            printf 'Linux - checking blockers...\n' > "${_stat[$i]}"
            local blocked=0
            if [ "$FORCE_ACTION" -ne 1 ] && ! check_update_blockers "$node"; then
                blocked=1
            fi
            if [ "$blocked" -eq 1 ]; then
                printf 'Linux - BLOCKED (update activity)\n' > "${_stat[$i]}"
                printf 'blocked\n'                           > "${_cmd_f[$i]}"
                exit 0
            fi

            printf 'Linux - checking health...\n' > "${_stat[$i]}"
            local health=0
            check_linux_node_health "$node" > /dev/null 2>&1
            health=$?

            # Build the exec command for this node.
            local exec_cmd
            if farm_is_dual_boot_node "$node"; then
                local _bios="" _def _n _b _lw _wu
                for _def in "${DUAL_BOOT_NODES[@]}"; do
                    IFS='|' read -r _n _b _lw _wu <<< "$_def"
                    [[ "$_n" == "$node" ]] && _bios="$_b" && break
                done
                local _tmpf
                _tmpf=$(mktemp /tmp/reboot_${node}_XXXXXX.sh)
                make_dualboot_reboot_script "$node" "$_bios" > "$_tmpf"
                chmod +x "$_tmpf"
                exec_cmd="bash $_tmpf; rm $_tmpf"
            else
                exec_cmd="ssh -t -F ~/.ssh/config -o LogLevel=ERROR $node \"$CMD_SSH_REBOOT\" ; sleep 3"
            fi

            if [ "$health" -eq 1 ]; then
                printf 'Linux - WARNING: active processes\n' > "${_stat[$i]}"
            else
                printf 'Linux - will reboot\n'              > "${_stat[$i]}"
            fi
            printf '%s\n' "$exec_cmd" > "${_cmd_f[$i]}"
        ) &
        _cpids[$i]=$!
    done

    # ── poll loop: update table as checks complete ────────────────────────────
    local _done_count=0 _sidx=0 _sc='|/-\' _sc_char
    while [ "$_done_count" -lt "$total_nodes" ]; do
        _done_count=0
        _sc_char="${_sc:$_sidx:1}"; _sidx=$(( (_sidx + 1) % 4 ))
        for i in "${!TABLE_NODES[@]}"; do
            if [ "${_done[$i]}" -eq 1 ]; then
                (( _done_count++ )); continue
            fi
            if [ -s "${_stat[$i]}" ]; then
                IFS= read -r TBL_STATUS[$i] < "${_stat[$i]}"
            else
                TBL_STATUS[$i]="checking... $_sc_char"
            fi
            if ! kill -0 "${_cpids[$i]}" 2>/dev/null; then
                wait "${_cpids[$i]}" 2>/dev/null
                _done[$i]=1; (( _done_count++ ))
                [ -s "${_stat[$i]}"  ] && IFS= read -r TBL_STATUS[$i] < "${_stat[$i]}"
                [ -s "${_cmd_f[$i]}" ] && IFS= read -r RES_CMD[$i]    < "${_cmd_f[$i]}"
            fi
        done
        _draw_table "Checking... [$_done_count/$total_nodes]"
        sleep 0.1
    done

    # Final result read for all nodes.
    for i in "${!TABLE_NODES[@]}"; do
        [ -s "${_stat[$i]}"  ] && IFS= read -r TBL_STATUS[$i] < "${_stat[$i]}"
        [ -s "${_cmd_f[$i]}" ] && IFS= read -r RES_CMD[$i]    < "${_cmd_f[$i]}"
    done
    rm -rf "$tmp_dir"

    # ── tally outcomes ────────────────────────────────────────────────────────
    local _n_will=0 _n_skip=0
    local -a BLOCKED_NODES=()
    for i in "${!TABLE_NODES[@]}"; do
        case "${RES_CMD[$i]}" in
            skip|"") (( _n_skip++ )) ;;
            blocked) (( _n_skip++ )); BLOCKED_NODES+=("${TABLE_NODES[$i]}") ;;
            *)       (( _n_will++ )) ;;
        esac
    done

    # ── confirm (inline footer — no extra table) ──────────────────────────────
    local _summary="${_n_will} queued${_n_skip:+, ${_n_skip} skipped}"
    [ "${#BLOCKED_NODES[@]}" -gt 0 ] && \
        _summary+=" — BLOCKED: ${BLOCKED_NODES[*]}"

    if [ "$AUTO_YES" -eq 0 ] && [ "$can_redraw" -eq 1 ]; then
        _draw_table "${_summary} — Proceed? [y/N]:"
        local _conf
        IFS= read -r -n 1 -s _conf < /dev/tty
        if [[ "$_conf" =~ ^[Yy]$ ]]; then
            # Move cursor back to table top so the exec table overwrites exactly.
            printf "\033[%dA\r" $(( total_nodes * 3 + 1 ))
        else
            echo ""; echo "Aborted."; exit 0
        fi
    else
        _draw_table "$_summary"
        if ! farm_confirm_yn "Are you sure? (y/n): " "$AUTO_YES" "n"; then
            echo "Aborted."; exit 0
        fi
        echo ""
    fi

    # ── security gate ─────────────────────────────────────────────────────────
    if [ "${#BLOCKED_NODES[@]}" -gt 0 ] && [ "$FORCE_ACTION" -ne 1 ]; then
        farm_print_error "Security stop: update-related activity detected."
        echo "Blocked node(s):"
        for node in "${BLOCKED_NODES[@]}"; do echo "  - $node"; done
        echo ""
        echo "Resolve updates first or rerun with --force to override."
        exit 1
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        farm_print_ok "Dry-run complete. No changes were made."
        exit 0
    fi

    # ── build exec arrays (ALL nodes included so exec table height matches) ───
    # Skipped/blocked nodes get a no-op command so run_commands_with_live_status
    # renders the same number of rows as the check table, enabling seamless
    # cursor-up overwrite.
    local -a reboot_exec_nodes=() reboot_exec_cmds=()
    for i in "${!TABLE_NODES[@]}"; do
        local node="${TABLE_NODES[$i]}"
        local cmd="${RES_CMD[$i]}"
        reboot_exec_nodes+=("$node")
        case "$cmd" in
            skip|blocked|"")
                reboot_exec_cmds+=("true")
                ;;
            local_reboot)
                reboot_exec_cmds+=("echo 'local reboot queued (follows after remotes)'; sleep 3")
                ;;
            win_reboot:*)
                local bios="${cmd#win_reboot:}"
                reboot_exec_cmds+=("echo '[$node] on Windows - setting next boot to Linux'; ssh -F ~/.ssh/config -o LogLevel=ERROR ${node}-win \"powershell -Command \\\"bcdedit /set '{fwbootmgr}' bootsequence '$bios'\\\"\"; sleep 2; echo '[$node] rebooting to Linux now'; ssh -F ~/.ssh/config -o LogLevel=ERROR ${node}-win 'shutdown /r /t 5'; sleep 5")
                ;;
            *)
                reboot_exec_cmds+=("$cmd")
                ;;
        esac
    done

    # ── execute ───────────────────────────────────────────────────────────────
    if [ "$RUN_NO_TMUX_UI" -eq 1 ]; then
        run_commands_with_live_status \
            "Executing remote reboot commands..." \
            reboot_exec_nodes reboot_exec_cmds
    else
        farm_tmux_reset_session "$SESSION"
        for idx in "${!reboot_exec_nodes[@]}"; do
            local n="${reboot_exec_nodes[$idx]}"
            local c="${reboot_exec_cmds[$idx]}"
            if farm_is_dual_boot_node "$n"; then
                farm_tmux_add_pane "$SESSION" "$c" "NODE: $n (dual-boot)"
            else
                farm_tmux_add_pane "$SESSION" "$c" "NODE: $n"
            fi
        done
        farm_tmux_apply_config "$SESSION"
        farm_launch_terminal "farm-reboot" "$X_START" "$SESSION" 1.0
    fi

    local_reboot_countdown() {
        local seconds="${1:-10}"
        echo "Rebooting local machine soon..."
        echo ""
        if ! farm_countdown_with_pause "$seconds" "Local reboot in"; then
            farm_print_warn "Local reboot cancelled by user. Remote node reboot continues."
            echo ""
            return 1
        fi
        return 0
    }

    # ── local machine reboot (after remotes finish) ───────────────────────────
    if [[ "$local_choice" =~ ^[Yy]$ ]]; then
        if [ "$RUN_NO_TMUX_UI" -ne 1 ]; then
            echo "Waiting for remote reboot sessions to finish..."
            while tmux has-session -t $SESSION 2>/dev/null; do sleep 2; done
            echo "Remote reboot sessions completed."
            echo ""
        fi
        if local_reboot_countdown 10; then
            systemctl reboot
        else
            echo ""
            echo "Local machine stays on."
            echo ""
        fi
    else
        echo "Remote reboot commands sent. Local machine stays on."
        echo ""
    fi
}

case "$MODE" in
    shutdown) run_shutdown ;;
    reboot) run_reboot ;;
    *)
        farm_print_error "Unknown mode: $MODE"
        echo "Use shutdown or reboot."
        exit 1
        ;;
esac
