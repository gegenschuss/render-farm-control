#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
cd "$(dirname "$0")"
source ../lib/config.sh

show_help() {
    cat << 'EOF'
Usage: ./status.sh [options]

Display detailed status for all farm nodes and local workstation.

Options:
  -h, --help    Show this help message
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_help
    exit 0
fi

"$FARM_SCRIPTS_DIR/lib/header.sh"
echo ""

farm_print_title "FARM STATUS"

# --- REMOTE STATUS SCRIPT ---
read -r -d '' STATUS_SCRIPT << 'EOF'
C_WARN='\033[1;33m'
C_OK='\033[1;32m'
C_ERR='\033[1;31m'
C_RESET='\033[0m'
C_BOLD='\033[1m'
printf "\n"
printf "  ${C_WARN}Uptime:${C_RESET}    %s\n" "$(uptime -p)"
printf "  ${C_WARN}Load:${C_RESET}      %s\n" \
    "$(awk '{print $1, $2, $3}' /proc/loadavg)"
printf "\n"
free -h | awk '/Mem:/ {
    printf "  \033[1;33mMemory:\033[0m    Used %s / %s   Free %s\n",
    $3, $2, $4
}'
printf "\n"
printf "  ${C_WARN}Disk:${C_RESET}\n"
df -h | awk '/^\// && $6 !~ /^\/mnt/ {
    printf "    %-24s %6s / %-6s  (%s)\n", $6, $3, $2, $5
}'
printf "\n"
printf "  ${C_WARN}GPU:${C_RESET}\n"
if command -v nvidia-smi &>/dev/null; then
    nvidia-smi \
        --query-gpu=index,name,temperature.gpu,utilization.gpu,memory.used,memory.total \
        --format=csv,noheader 2>/dev/null \
        | while IFS=',' read -r idx name temp util mem_used mem_total; do
        [[ "$idx" =~ ^[0-9]+$ ]] || continue
        printf "    ${C_BOLD}GPU%s${C_RESET}  %s\n" \
            "${idx// /}" "${name// /}"
        printf "          Temp:%s   Util:%s\n" \
            "$temp" "$util"
        printf "          VRAM:%s /%s\n" \
            "$mem_used" "$mem_total"
    done
else
    printf "    nvidia-smi not found\n"
fi
printf "\n"
printf "  ${C_WARN}Installed Versions:${C_RESET}\n"
HVER=$(ls -1d /opt/hfs* 2>/dev/null | sort -V | tail -1)
if [ -n "$HVER" ]; then
    HVER=$(basename "$HVER")
else
    HVER="not installed"
fi
printf "    Houdini:  %s\n" "$HVER"
printf "\n"
if [ -f /var/run/reboot-required ]; then
    printf "  ${C_WARN}Reboot:${C_RESET}    ${C_ERR}[REQUIRED]${C_RESET}\n"
else
    printf "  ${C_WARN}Reboot:${C_RESET}    ${C_OK}[NOT REQUIRED]${C_RESET}\n"
fi
printf "\n"
printf "  ${C_WARN}Process Check:${C_RESET}\n"
WARNINGS=0
APT_RUNNING=$(pgrep -x apt-get || pgrep -x dpkg || pgrep -xa unattended-upgrades)
if [ -n "$APT_RUNNING" ]; then
    printf "    ${C_ERR}[WARNING]${C_RESET}  APT/DPKG update in progress\n"
    WARNINGS=1
fi
CPU_USAGE=$(top -bn1 | grep 'Cpu(s)' | awk '{print $2}' | cut -d. -f1)
if [ -n "$CPU_USAGE" ] && [ "$CPU_USAGE" -gt 80 ] 2>/dev/null; then
    printf "    ${C_ERR}[WARNING]${C_RESET}  High CPU usage: %s%%\n" "$CPU_USAGE"
    WARNINGS=1
fi
if command -v nvidia-smi &>/dev/null; then
    GPU_USAGE=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null \
        | awk '{sum+=$1} END {print sum/NR}' | cut -d. -f1)
    if [ -n "$GPU_USAGE" ] && [ "$GPU_USAGE" -gt 80 ] 2>/dev/null; then
        printf "    ${C_ERR}[WARNING]${C_RESET}  High GPU usage: %s%%\n" "$GPU_USAGE"
        WARNINGS=1
    fi
fi
if [ $WARNINGS -eq 0 ]; then
    printf "    ${C_OK}[OK]${C_RESET}       No active processes\n"
fi
printf "\n"
EOF

B64_STATUS=$(echo "$STATUS_SCRIPT" | base64 -w 0)

# ---------------------------------------------------------------------------
# HELPER FUNCTIONS
# ---------------------------------------------------------------------------

get_linux_versions_remote() {
    local target="$1"
    ssh -F ~/.ssh/config -o LogLevel=ERROR "$target" '
HVER=$(ls -1d /opt/hfs* 2>/dev/null | sort -V | tail -1)
if [ -n "$HVER" ]; then
    HVER=$(basename "$HVER")
else
    HVER="not installed"
fi

RENDER=""
pgrep -x husk >/dev/null 2>&1 && RENDER="husk"
pgrep -x mantra >/dev/null 2>&1 && RENDER="${RENDER:+${RENDER}+}mantra"
printf "%s|%s\n" "$HVER" "$RENDER"
' 2>/dev/null
}

get_linux_versions_local() {
    local HVER RENDER=""
    HVER=$(ls -1d /opt/hfs* 2>/dev/null | sort -V | tail -1)
    if [ -n "$HVER" ]; then
        HVER=$(basename "$HVER")
    else
        HVER="not installed"
    fi

    pgrep -x husk >/dev/null 2>&1 && RENDER="husk"
    pgrep -x mantra >/dev/null 2>&1 && RENDER="${RENDER:+${RENDER}+}mantra"
    printf "%s|%s\n" "$HVER" "$RENDER"
}

shorten_text() {
    local text="$1"
    local max_len="$2"
    if [ "${#text}" -le "$max_len" ]; then
        printf "%s" "$text"
    else
        printf "%s..." "${text:0:$((max_len-3))}"
    fi
}

compact_houdini_version() {
    local raw="$1"
    if [ "$raw" = "not installed" ] || [ "$raw" = "n/a" ]; then
        printf "%s" "$raw"
        return
    fi
    local ver="${raw#hfs}"
    printf "%s" "$ver"
}

print_node_header() {
    local label="$1" status="$2"
    local width=60
    local line
    line=$(printf "%*s" "$width" "" | tr " " "-")
    echo -e "${FARM_C_WARN}${line}${FARM_C_RESET}"
    if [[ "$status" == "ONLINE" || "$status" == "ONLINE (Linux)" ]]; then
        printf "  ${FARM_C_NODE}%-14s${FARM_C_RESET}  ${FARM_C_OK}%s${FARM_C_RESET}\n" \
            "$label" "$status"
    elif [[ "$status" == "OFFLINE" ]]; then
        printf "  ${FARM_C_NODE}%-14s${FARM_C_RESET}  ${FARM_C_ERR}%s${FARM_C_RESET}\n" \
            "$label" "$status"
    elif [[ "$status" == "WINDOWS" ]]; then
        printf "  ${FARM_C_NODE}%-14s${FARM_C_RESET}  ${FARM_C_WARN}%s${FARM_C_RESET}\n" \
            "$label" "$status"
    else
        printf "  ${FARM_C_NODE}%-14s${FARM_C_RESET}  %s\n" \
            "$label" "$status"
    fi
    echo -e "${FARM_C_WARN}${line}${FARM_C_RESET}"
}

# Format a summary line (pipe-delimited) into a short colored table status string.
format_node_status_line() {
    local state="$1" apps="$2" hver="$3"
    local h_short result
    case "$state" in
        linux_ready|workstation_ready)
            h_short=$(shorten_text "$(compact_houdini_version "$hver")" 16)
            if [ "$state" = "workstation_ready" ]; then
                result="${FARM_C_OK}workstation ready${FARM_C_RESET}   H ${h_short}"
            else
                result="${FARM_C_OK}linux ready${FARM_C_RESET}   H ${h_short}"
            fi
            [ -n "$apps" ] && result="${result}   ${FARM_C_ERR}render: ${apps}${FARM_C_RESET}"
            printf '%b' "$result"
            ;;
        windows_idle)
            printf '%b' "${FARM_C_WARN}windows — idle${FARM_C_RESET}"
            ;;
        windows_apps)
            local short_apps
            short_apps=$(shorten_text "$apps" 40)
            printf '%b' "${FARM_C_WARN}windows — ${short_apps}${FARM_C_RESET}"
            ;;
        offline)
            printf '%b' "${FARM_C_ERR}offline${FARM_C_RESET}"
            ;;
        *)
            printf '%s' "${state:-unknown}"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# NODE CHECK FUNCTIONS
# ---------------------------------------------------------------------------

# check_node_status NODE OUTPUT_FILE SUMMARY_FILE [STAT_FILE]
# Runs detailed check; writes live status updates to STAT_FILE if provided.
check_node_status() {
    local node="$1"
    local output_file="$2"
    local summary_file="$3"
    local stat_file="${4:-}"
    local summary_line=""

    # Write live status text (bypasses the { } > output_file redirect via explicit >).
    _wstat() { [ -n "$stat_file" ] && printf '%s\n' "$1" > "$stat_file" 2>/dev/null; }

    _wstat "detecting OS..."

    {
        if farm_is_dual_boot_node "$node"; then
            detect_node_os "$node"
            OS_STATUS=$?

            case $OS_STATUS in
                1)
                    # Windows
                    _wstat "Windows — checking tasks..."
                    print_node_header "$node" "WINDOWS"
                    echo "$(farm_node_tag "$node") checking important Windows tasks (Premiere, Illustrator, Photoshop, After Effects, Reaper)..."
                    TASKS=$(farm_get_windows_tasks "$node")
                    if [ -z "$TASKS" ]; then
                        echo "$(farm_node_tag "$node") no important Windows tasks running."
                        summary_line="$node|windows_idle||n/a"
                        printf "%s\n" "$summary_line" > "$summary_file"
                        printf "windows — idle\n" > "$stat_file"
                    else
                        echo "$(farm_node_tag "$node") important Windows tasks running:"
                        while read -r TASK; do
                            [ -n "$TASK" ] && echo "  - $TASK"
                        done <<< "$TASKS"
                        TASKS_INLINE=$(echo "$TASKS" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
                        summary_line="$node|windows_apps|$TASKS_INLINE|n/a"
                        printf "%s\n" "$summary_line" > "$summary_file"
                        printf "windows — %s\n" "$TASKS_INLINE" > "$stat_file"
                    fi
                    LOGGED_IN=$(ssh -F ~/.ssh/config -o BatchMode=yes -o LogLevel=ERROR \
                        "${node}-win" \
                        'powershell -Command "(Get-WMIObject Win32_ComputerSystem).UserName"' \
                        2>/dev/null)
                    printf "\n"
                    printf "  ${FARM_C_WARN}OS:${FARM_C_RESET}        Windows\n"
                    if [ -n "$LOGGED_IN" ]; then
                        printf "  ${FARM_C_WARN}User:${FARM_C_RESET}      %s\n" "$LOGGED_IN"
                    else
                        printf "  ${FARM_C_WARN}User:${FARM_C_RESET}      No active session\n"
                    fi
                    printf "\n"
                    ;;
                2)
                    # Linux
                    _wstat "Linux — fetching details..."
                    print_node_header "$node" "ONLINE (Linux)"
                    ssh -F ~/.ssh/config -o LogLevel=ERROR "$node" "echo '$B64_STATUS' | base64 -d | bash"
                    VERSION_DATA=$(get_linux_versions_remote "$node")
                    IFS='|' read -r HVER RENDER_INFO <<< "$VERSION_DATA"
                    HVER=${HVER:-unknown}
                    summary_line="$node|linux_ready|${RENDER_INFO:-}|$HVER"
                    ;;
                0)
                    # Offline
                    print_node_header "$node" "OFFLINE"
                    echo ""
                    summary_line="$node|offline||n/a"
                    ;;
            esac
        else
            # Linux-only node
            _wstat "pinging..."
            if ! ping -c 1 -W 1 "$node" &>/dev/null; then
                print_node_header "$node" "OFFLINE"
                echo ""
                summary_line="$node|offline||n/a"
            else
                _wstat "Linux — fetching details..."
                print_node_header "$node" "ONLINE"
                ssh -F ~/.ssh/config -o LogLevel=ERROR "$node" "echo '$B64_STATUS' | base64 -d | bash"
                VERSION_DATA=$(get_linux_versions_remote "$node")
                IFS='|' read -r HVER RENDER_INFO <<< "$VERSION_DATA"
                HVER=${HVER:-unknown}
                summary_line="$node|linux_ready|${RENDER_INFO:-}|$HVER"
            fi
        fi
    } > "$output_file"

    # Only overwrite if summary_line was set (guards against { } propagation issues).
    [ -n "$summary_line" ] && printf "%s\n" "$summary_line" > "$summary_file"

    # Write final colored status line for the table.
    if [ -n "$summary_line" ] && [ -n "$stat_file" ]; then
        local _node _state _apps _hver
        IFS='|' read -r _node _state _apps _hver <<< "$summary_line"
        format_node_status_line "$_state" "$_apps" "$_hver" > "$stat_file"
    fi
}

# check_local_status OUTPUT_FILE [STAT_FILE]
check_local_status() {
    local output_file="$1"
    local stat_file="${2:-}"

    _wstat() { [ -n "$stat_file" ] && printf '%s\n' "$1" > "$stat_file" 2>/dev/null; }

    _wstat "fetching local status..."

    {
        print_node_header "$FARM_LOCAL_NAME" "ONLINE"
        printf "\n"
        printf "  ${FARM_C_WARN}Uptime:${FARM_C_RESET}    %s\n" "$(uptime -p)"
        printf "  ${FARM_C_WARN}Load:${FARM_C_RESET}      %s\n" \
            "$(awk '{print $1, $2, $3}' /proc/loadavg)"
        printf "\n"
        free -h | awk '/Mem:/ {
            printf "  \033[1;33mMemory:\033[0m    Used %s / %s   Free %s\n",
            $3, $2, $4
        }'
        printf "\n"
        printf "  ${FARM_C_WARN}Disk:${FARM_C_RESET}\n"
        df -h | awk '/^\// && $6 !~ /^\/mnt/ {
            printf "    %-24s %6s / %-6s  (%s)\n", $6, $3, $2, $5
        }'
        printf "\n"
        printf "  ${FARM_C_WARN}GPU:${FARM_C_RESET}\n"
        if command -v nvidia-smi &>/dev/null; then
            nvidia-smi \
                --query-gpu=index,name,temperature.gpu,utilization.gpu,memory.used,memory.total \
                --format=csv,noheader 2>/dev/null \
                | while IFS=',' read -r idx name temp util mem_used mem_total; do
                [[ "$idx" =~ ^[0-9]+$ ]] || continue
                printf "    \033[1mGPU%s\033[0m  %s\n" \
                    "${idx// /}" "${name// /}"
                printf "          Temp:%s   Util:%s\n" \
                    "$temp" "$util"
                printf "          VRAM:%s /%s\n" \
                    "$mem_used" "$mem_total"
            done
        else
            printf "    nvidia-smi not found\n"
        fi
        printf "\n"
        printf "  ${FARM_C_WARN}Installed Versions:${FARM_C_RESET}\n"
        _LOCAL_HVER=$(ls -1d /opt/hfs* 2>/dev/null | sort -V | tail -1)
        [ -n "$_LOCAL_HVER" ] && _LOCAL_HVER=$(basename "$_LOCAL_HVER") || _LOCAL_HVER="not installed"
        printf "    Houdini:  %s\n" "$_LOCAL_HVER"
        printf "\n"
        if [ -f /var/run/reboot-required ]; then
            printf "  ${FARM_C_WARN}Reboot:${FARM_C_RESET}    ${FARM_C_ERR}[REQUIRED]${FARM_C_RESET}\n"
        else
            printf "  ${FARM_C_WARN}Reboot:${FARM_C_RESET}    ${FARM_C_OK}[NOT REQUIRED]${FARM_C_RESET}\n"
        fi
        printf "\n"
        printf "  ${FARM_C_WARN}Process Check:${FARM_C_RESET}\n"
        WARNINGS=0
        APT_RUNNING=$(pgrep -x apt-get || pgrep -x dpkg || pgrep -xa unattended-upgrades)
        if [ -n "$APT_RUNNING" ]; then
            printf "    ${FARM_C_ERR}[WARNING]${FARM_C_RESET}  APT/DPKG update in progress\n"
            WARNINGS=1
        fi
        CPU_USAGE=$(top -bn1 | grep 'Cpu(s)' | awk '{print $2}' | cut -d. -f1)
        if [ -n "$CPU_USAGE" ] && [ "$CPU_USAGE" -gt 80 ] 2>/dev/null; then
            printf "    ${FARM_C_ERR}[WARNING]${FARM_C_RESET}  High CPU usage: %s%%\n" "$CPU_USAGE"
            WARNINGS=1
        fi
        if command -v nvidia-smi &>/dev/null; then
            GPU_USAGE=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null \
                | awk '{sum+=$1} END {print sum/NR}' | cut -d. -f1)
            if [ -n "$GPU_USAGE" ] && [ "$GPU_USAGE" -gt 80 ] 2>/dev/null; then
                printf "    ${FARM_C_ERR}[WARNING]${FARM_C_RESET}  High GPU usage: %s%%\n" "$GPU_USAGE"
                WARNINGS=1
            fi
        fi
        [ $WARNINGS -eq 0 ] && printf "    ${FARM_C_OK}[OK]${FARM_C_RESET}       No active processes\n"
        printf "\n"
    } > "$output_file"

    # Write final colored status line for the table.
    local _ldata _lhver _lrender
    _ldata=$(get_linux_versions_local)
    IFS='|' read -r _lhver _lrender <<< "$_ldata"
    if [ -n "$stat_file" ]; then
        format_node_status_line "workstation_ready" "${_lrender:-}" "${_lhver:-unknown}" > "$stat_file"
    fi
}

# ---------------------------------------------------------------------------
# LIVE TABLE SETUP
# ---------------------------------------------------------------------------

TABLE_NODES=("${NODES[@]}" "$FARM_LOCAL_NAME")
local_idx=$(( ${#TABLE_NODES[@]} - 1 ))
total_nodes=${#TABLE_NODES[@]}

can_redraw=0; [ -t 1 ] && can_redraw=1
term_cols=$(tput cols 2>/dev/null)
[[ "$term_cols" =~ ^[0-9]+$ ]] || term_cols=120
table_w=$(( term_cols - 6 )); [ "$table_w" -lt 24 ] && table_w=24

TBL_STATUS=()
for i in "${!TABLE_NODES[@]}"; do TBL_STATUS[$i]="checking..."; done

_tbl_drawn=0 _tbl_footer_lines=0
_draw_table() {
    local footer="${1:-}"
    if [ "$can_redraw" -eq 1 ] && [ "$_tbl_drawn" -eq 1 ]; then
        printf "\033[%dA" $(( total_nodes * 3 + _tbl_footer_lines ))
    fi
    for i in "${!TABLE_NODES[@]}"; do
        printf "  ${FARM_C_NODE}%s${FARM_C_RESET}\033[K\n" "${TABLE_NODES[$i]}:"
        printf "    %b\033[K\n" "${TBL_STATUS[$i]}"
        printf "\033[K\n"
    done
    _tbl_footer_lines=0
    if [ -n "$footer" ]; then
        printf "  %s\033[K\n" "$footer"
        _tbl_footer_lines=1
    fi
    _tbl_drawn=1
}

# ---------------------------------------------------------------------------
# TEMP FILES + BACKGROUND CHECKS
# ---------------------------------------------------------------------------

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

_stat=() _out=() _sum=() _done=() _cpids=()
for i in "${!TABLE_NODES[@]}"; do
    _stat[$i]="$TMP_DIR/s${i}"
    _out[$i]="$TMP_DIR/o${i}"
    _sum[$i]="$TMP_DIR/m${i}"
    _done[$i]=0
done

for i in "${!TABLE_NODES[@]}"; do
    node="${TABLE_NODES[$i]}"
    if [[ "$node" == "$FARM_LOCAL_NAME" ]]; then
        ( check_local_status "${_out[$i]}" "${_stat[$i]}" ) 2>/dev/null &
    else
        ( check_node_status "$node" "${_out[$i]}" "${_sum[$i]}" "${_stat[$i]}" ) 2>/dev/null &
    fi
    _cpids[$i]=$!
done

# ---------------------------------------------------------------------------
# INITIAL RENDER + POLL LOOP
# ---------------------------------------------------------------------------

echo ""
_draw_table "Checking... [0/$total_nodes]"

_done_count=0
_sidx=0
_sc='|/-\'
_sc_char=''
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
            [ -s "${_stat[$i]}" ] && IFS= read -r TBL_STATUS[$i] < "${_stat[$i]}"
        fi
    done
    _draw_table "Checking... [$_done_count/$total_nodes]"
    sleep 0.1
done

# Final status: compute from summary files in main-script context (avoids
# background-subshell fd issues), falling back to stat file if no summary.
for i in "${!TABLE_NODES[@]}"; do
    if [ -s "${_sum[$i]}" ]; then
        _sl=""
        IFS= read -r _sl < "${_sum[$i]}"
        if [ -n "$_sl" ]; then
            _sn="" _ss="" _sa="" _sh=""
            IFS='|' read -r _sn _ss _sa _sh <<< "$_sl"
            TBL_STATUS[$i]="$(format_node_status_line "$_ss" "$_sa" "$_sh")"
        fi
    elif [ -s "${_stat[$i]}" ]; then
        IFS= read -r TBL_STATUS[$i] < "${_stat[$i]}"
    fi
done
_draw_table
echo ""

# ---------------------------------------------------------------------------
# DETAIL VIEW  (press m to page through per-node full output)
# ---------------------------------------------------------------------------

farm_print_rule
echo ""

if [ -t 0 ]; then
    _detail_files=()
    _detail_labels=()
    for idx in "${!NODES[@]}"; do
        [ -f "${_out[$idx]}" ] && \
            _detail_files+=("${_out[$idx]}") && \
            _detail_labels+=("${NODES[$idx]}")
    done
    _detail_files+=("${_out[$local_idx]}")
    _detail_labels+=("$FARM_LOCAL_NAME")

    _total_details=${#_detail_files[@]}
    _cur=0
    while [ "$_cur" -lt "$_total_details" ]; do
        _remaining=$(( _total_details - _cur - 1 ))
        if [ "$_cur" -eq 0 ]; then
            _prompt="  Press m for details (${_detail_labels[$_cur]}), any other key to exit "
        else
            _prompt="  Press m for next (${_detail_labels[$_cur]}${_remaining:+, ${_remaining} left}), any other key to exit "
        fi
        read -n 1 -s -r -p "$_prompt" _key
        echo ""
        if [[ "$_key" == "m" || "$_key" == "M" ]]; then
            clear
            echo ""
            cat "${_detail_files[$_cur]}"
            farm_print_rule
            echo ""
            _cur=$(( _cur + 1 ))
        else
            break
        fi
    done
else
    # Non-interactive: print everything.
    for i in "${!TABLE_NODES[@]}"; do
        [ -f "${_out[$i]}" ] && cat "${_out[$i]}"
    done
    farm_print_rule
    echo ""
fi
